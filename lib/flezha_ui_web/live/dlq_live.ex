defmodule FlezhaUiWeb.DlqLive do
  @moduledoc """
  Dead-letter queue: the payloads that failed and were parked.

  Replay and drop are the only destructive verbs this screen has. Both are
  confirm-gated. A replay re-sends the payload as a new input and the
  controller waits out its own grace period before answering whether the entry
  left the queue or parked again, so the screen reports that answer as it is.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000
  use FlezhaUiWeb.Inspect, kinds: ~w(entry)

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> assign(
        page_title: "Dead-letter queue",
        filter: nil,
        groups: [],
        entries: [],
        stats: [],
        load_error: nil,
        confirm: nil,
        replay_outcome: nil
      )

    {:ok, socket}
  end

  # `?class=` narrows the listing to one relay class, which is how an open
  # problem about parked entries links here. A parked entry opens in the
  # inspector from `?inspect=entry:<ref>`.
  @impl true
  def handle_params(params, _uri, socket) do
    filter = params["class"] || ""

    socket =
      if filter == socket.assigns.filter,
        do: socket,
        else: socket |> assign(filter: filter) |> refresh()

    {:noreply, inspect_params(socket, params)}
  end

  # Holding still while a modal is open keeps a row from moving underneath the
  # operator between reading it and confirming.
  @impl FlezhaUiWeb.Live.Refresh
  def refresh_paused?(socket),
    do: socket.assigns.confirm != nil or socket.assigns[:inspected] != nil

  @impl true
  def handle_event("filter", %{"filter" => %{"relay_class" => value}}, socket) do
    query = if value == "", do: %{}, else: %{class: value}
    {:noreply, push_patch(socket, to: ~p"/dlq?#{query}")}
  end

  @impl true
  def handle_event("confirm", %{"action" => action, "ref" => ref}, socket)
      when action in ["replay", "drop"] do
    {:noreply, assign(socket, confirm: %{action: action, ref: ref}, replay_outcome: nil)}
  end

  @impl true
  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, confirm: nil)}
  end

  @impl true
  def handle_event("drop", %{"ref" => ref}, socket) do
    case NodeManager.dlq_drop(ref, socket.assigns.flezha_token) do
      :ok ->
        {:noreply,
         socket
         |> assign(confirm: nil)
         |> put_flash(:info, "Entry dropped. Its payload is gone.")
         |> refresh()
         |> push_patch(to: inspect_path(socket, nil))}

      {:error, reason} ->
        {:noreply, socket |> assign(confirm: nil) |> put_flash(:error, error_message(reason))}
    end
  end

  # The controller answers only after its grace period, so the call runs off
  # the screen's process and the screen says it is waiting.
  @impl true
  def handle_event("replay", %{"ref" => ref}, socket) do
    token = socket.assigns.flezha_token

    {:noreply,
     socket
     |> assign(confirm: nil, replay_outcome: {:pending, ref})
     |> push_patch(to: inspect_path(socket, nil))
     |> start_async(:replay, fn -> {ref, NodeManager.dlq_replay(ref, token)} end)}
  end

  @impl true
  def handle_async(:replay, {:ok, {ref, answer}}, socket) do
    outcome =
      case answer do
        {:ok, %{outcome: :removed}} -> {:replayed, ref}
        {:ok, %{outcome: :re_parked, generation: generation}} -> {:reparked, ref, generation}
        {:error, reason} -> {:refused, ref, reason}
      end

    {:noreply, socket |> assign(replay_outcome: outcome) |> refresh()}
  end

  def handle_async(:replay, {:exit, reason}, socket) do
    {:noreply, assign(socket, replay_outcome: {:refused, nil, {:remote_error, reason}})}
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token

    case NodeManager.dlq_list(socket.assigns.filter, token) do
      {:ok, entries} ->
        decorated = Enum.map(entries, &decorate/1)

        assign(socket,
          entries: decorated,
          groups: group_by_tasklet(decorated, socket.assigns.filter, token),
          load_error: nil,
          stats:
            token |> NodeManager.dlq_stats() |> NodeManager.ok_or([]) |> Enum.filter(&parked?/1)
        )

      {:error, reason} ->
        assign(socket, entries: [], groups: [], stats: [], load_error: reason)
    end
  end

  # With a durability backend, the controller keeps an emptied tasklet until
  # the tier has shipped it, and reports it at zero meanwhile.
  defp parked?(stat), do: (stat[:entries] || 0) > 0

  # Grouped the way the controller stores and ships them: one directory per
  # `{relay_class, tasklet_id}` pair. The controller is asked which pairs exist
  # so a tasklet whose entries are filtered out still shows as a group with a
  # count, rather than vanishing.
  defp group_by_tasklet(entries, filter, token) do
    parked = Enum.group_by(entries, &{&1.relay_class, &1.tasklet_id})

    known =
      filter
      |> NodeManager.dlq_tasklets(token)
      |> NodeManager.ok_or([])
      |> Enum.map(fn {class, tasklet} -> {to_string(class), to_string(tasklet)} end)

    (known ++ Map.keys(parked))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {class, tasklet} = key ->
      group_entries = Map.get(parked, key, [])

      %{
        relay_class: class,
        tasklet_id: tasklet,
        # Oldest first within a group, as the flat listing was.
        entries: Enum.sort_by(group_entries, &(&1.ts_ms || 0)),
        parked: length(group_entries)
      }
    end)
    |> Enum.reject(&(&1.parked == 0 and &1.entries == []))
  end

  # `entry_ref` is the `class/tasklet/id` triple the controller's own verbs
  # take, so the UI addresses entries exactly as the CLI does.
  defp decorate(entry) do
    %{
      ref: "#{entry["relay_class"]}/#{entry["tasklet_id"]}/#{entry["id"]}",
      relay_class: entry["relay_class"],
      tasklet_id: entry["tasklet_id"],
      cell_key: entry["cell_key"],
      channel: entry["channel"],
      generation: entry["generation"] || 1,
      ts_ms: entry["ts_ms"],
      attempts: entry["attempts"],
      payload_bytes: entry["payload_bytes"],
      replaying?: entry["status"] == "replaying",
      error: entry["error"]
    }
  end
end
