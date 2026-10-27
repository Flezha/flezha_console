defmodule FlezhaConsoleWeb.DlqLive do
  @moduledoc """
  Dead-letter queue: the payloads that failed and were parked.

  Replay and drop are the only destructive verbs this screen has. Both are
  confirm-gated. A replay re-sends the payload as a new input and the
  controller waits out its own grace period before answering whether the entry
  left the queue or parked again, so the screen reports that answer as it is.

  Marking a dead letter seen changes nothing on the controller: it is the
  console's own record (`FlezhaConsole.DeadLetters`), and a seen dead letter
  is listed only while "Show seen" is on.
  """

  use FlezhaConsoleWeb, :live_view

  use FlezhaConsoleWeb.Live.Refresh, every: 5_000
  use FlezhaConsoleWeb.Inspect, kinds: ~w(entry)

  alias FlezhaConsole.DeadLetters
  alias FlezhaConsole.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> assign(
        page_title: "Dead-letter queue",
        filter: nil,
        show_seen?: false,
        groups: [],
        entries: [],
        shown: [],
        stats: [],
        load_error: nil,
        confirm: nil,
        replay_outcome: nil
      )

    {:ok, socket}
  end

  # `?class=` narrows the listing to one relay class, which is how an open
  # problem about parked entries links here, and `?seen=shown` lists the seen
  # ones too. A parked entry opens in the inspector from `?inspect=entry:<ref>`.
  @impl true
  def handle_params(params, _uri, socket) do
    filter = params["class"] || ""
    show_seen? = params["seen"] == "shown"

    socket =
      if {filter, show_seen?} == {socket.assigns.filter, socket.assigns.show_seen?},
        do: socket,
        else: socket |> assign(filter: filter, show_seen?: show_seen?) |> refresh()

    {:noreply, inspect_params(socket, params)}
  end

  # Holding still while a modal is open keeps a row from moving underneath the
  # operator between reading it and confirming.
  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_paused?(socket),
    do: socket.assigns.confirm != nil or socket.assigns[:inspected] != nil

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    query =
      [class: filter["relay_class"], seen: filter["show_seen"] == "true" && "shown"]
      |> Enum.reject(fn {_key, value} -> value in [nil, "", false] end)

    {:noreply, push_patch(socket, to: ~p"/dlq?#{query}")}
  end

  # Marked from what this screen listed, so the generation marked is the one
  # the operator saw, never one a client names.
  @impl true
  def handle_event("mark_seen", %{"ref" => ref}, socket) do
    {:noreply, mark_seen(socket, &(&1.ref == ref))}
  end

  def handle_event("mark_group_seen", %{"class" => class, "tasklet" => tasklet}, socket) do
    {:noreply, mark_seen(socket, &(&1.relay_class == class and &1.tasklet_id == tasklet))}
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
      {:ok, _dropped} ->
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

  defp mark_seen(socket, which) do
    case Enum.filter(socket.assigns.entries, &(which.(&1) and not &1.seen?)) do
      [] ->
        socket

      # No toast: the listing and its sentence say so, and a toast would
      # cover "Show seen", the control an operator reaches for next.
      entries ->
        :ok = DeadLetters.mark_seen(entries, socket.assigns.current_scope.user.email)
        refresh(socket)
    end
  end

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh(socket) do
    %{filter: filter, show_seen?: show_seen?, flezha_token: token} = socket.assigns

    case NodeManager.dlq_list(filter, token) do
      {:ok, entries} ->
        decorated = Enum.map(entries, &decorate/1)
        seen = DeadLetters.seen(decorated)

        decorated =
          Enum.map(decorated, &%{&1 | seen?: MapSet.member?(seen, {&1.ref, &1.generation})})

        shown = if show_seen?, do: decorated, else: Enum.reject(decorated, & &1.seen?)

        assign(socket,
          entries: decorated,
          shown: shown,
          groups: group_by_tasklet(decorated, shown, filter, token),
          load_error: nil,
          stats:
            token |> NodeManager.dlq_stats() |> NodeManager.ok_or([]) |> Enum.filter(&parked?/1)
        )

      {:error, reason} ->
        assign(socket, entries: [], shown: [], groups: [], stats: [], load_error: reason)
    end
  end

  @doc ~S|"2 dead letters are marked seen and hidden."|
  def hidden_seen(count, noun, plural \\ nil),
    do:
      "#{Words.count(count, noun, plural)} #{if count == 1, do: "is", else: "are"} marked seen and hidden."

  # With a durability backend, the controller keeps an emptied tasklet until
  # the tier has shipped it, and reports it at zero meanwhile.
  defp parked?(stat), do: (stat[:entries] || 0) > 0

  # Grouped the way the controller stores and ships them: one directory per
  # `{relay_class, tasklet_id}` pair. The controller is asked which pairs exist
  # so a tasklet whose entries are filtered out still shows as a group with a
  # count, rather than vanishing. A group lists what is `shown` and counts
  # every entry, and how many of them are seen.
  defp group_by_tasklet(entries, shown, filter, token) do
    parked = Enum.group_by(entries, &{&1.relay_class, &1.tasklet_id})
    listed = Enum.group_by(shown, &{&1.relay_class, &1.tasklet_id})

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
        entries: listed |> Map.get(key, []) |> Enum.sort_by(&(&1.ts_ms || 0)),
        parked: length(group_entries),
        seen: Enum.count(group_entries, & &1.seen?)
      }
    end)
    |> Enum.reject(&(&1.entries == []))
  end

  # `entry_ref` is the `class/tasklet/id` triple the controller's own verbs
  # take, so the UI addresses entries exactly as the CLI does.
  defp decorate(entry) do
    %{
      ref: DeadLetters.ref(entry),
      relay_class: entry["relay_class"],
      tasklet_id: entry["tasklet_id"],
      cell_key: entry["cell_key"],
      channel: entry["channel"],
      generation: DeadLetters.generation(entry),
      seen?: false,
      ts_ms: entry["ts_ms"],
      attempts: entry["attempts"],
      payload_bytes: entry["payload_bytes"],
      replaying?: entry["status"] == "replaying",
      error: park_error(entry["error"])
    }
  end

  # A sink's park stores the controller's error object as JSON text; a
  # tasklet's failure is plain text.
  defp park_error("{" <> _ = text) do
    case Jason.decode(text) do
      {:ok, %{"code" => code, "message" => message}} ->
        error_message(%{code: code, message: message})

      _other ->
        text
    end
  end

  defp park_error(error), do: error
end
