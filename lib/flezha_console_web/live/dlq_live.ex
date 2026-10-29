defmodule FlezhaConsoleWeb.DlqLive do
  @moduledoc """
  Dead-letter queue: the payloads that failed and were parked, on every
  controller. Each entry names the controller holding it, and replay and drop
  reach it there.

  Replay and drop are the only destructive verbs this screen has. Both are
  confirm-gated. A replay re-sends the payload as a new input and the
  controller waits out its own grace period before answering whether the entry
  left the queue or parked again, so the screen reports that answer as it is.

  Marking a dead letter seen changes nothing on the controller: it is the
  console's own record (`FlezhaConsole.DeadLetters`), and a seen dead letter
  is listed only while "Show seen" is on.

  The queue can hold thousands, so the listing reads the newest page of them
  from the controller and groups that page by tasklet; each group states how
  many its tasklet parks in all, from the controller's statistics.
  """

  use FlezhaConsoleWeb, :live_view

  use FlezhaConsoleWeb.Live.Refresh, every: 5_000, background: true
  use FlezhaConsoleWeb.Inspect, kinds: ~w(entry)

  alias FlezhaConsole.DeadLetters
  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.Live.Sections

  @listing "dlq"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> assign(
        page_title: "Dead-letter queue",
        filter: nil,
        controller: nil,
        show_seen?: false,
        groups: [],
        listed: [],
        total: 0,
        entries: [],
        shown: [],
        stats: [],
        unreachable: [],
        load_error: nil,
        confirm: nil,
        replay_outcome: nil
      )

    {:ok, socket}
  end

  # `?class=` narrows the listing to one relay class, which is how an open
  # problem about parked entries links here, `?controller=` to the entries one
  # controller holds, and `?seen=shown` lists the seen ones too. A parked entry
  # opens in the inspector from `?inspect=entry:<ref>`.
  @impl true
  def handle_params(params, _uri, socket) do
    filter = params["class"] || ""
    controller = params["controller"] || ""
    show_seen? = params["seen"] == "shown"
    %{filter: was_filter, controller: was_controller, show_seen?: was_seen} = socket.assigns

    socket =
      if {filter, controller, show_seen?} == {was_filter, was_controller, was_seen},
        do: socket,
        else:
          socket
          |> assign(filter: filter, controller: controller, show_seen?: show_seen?)
          |> read_when_connected()

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
      [
        class: filter["relay_class"],
        controller: filter["controller"],
        seen: filter["show_seen"] == "true" && "shown"
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, "", false] end)

    {:noreply, push_patch(socket, to: ~p"/dlq?#{query}")}
  end

  # Marked from what this screen listed, so the generation marked is the one
  # the operator saw, never one a client names.
  @impl true
  def handle_event("mark_seen", %{"ref" => ref}, socket) do
    {:noreply, mark_seen(socket, &(&1.ref == ref))}
  end

  # A group holds more entries than the page shows, so its class is listed
  # once, on the click, for every entry to mark.
  def handle_event("mark_group_seen", %{"class" => class, "tasklet" => tasklet}, socket) do
    case NodeManager.dlq_list(class, socket.assigns.flezha_token) do
      {:ok, %{rows: entries}} ->
        held =
          entries
          |> Enum.map(&decorate/1)
          |> Enum.filter(&(&1.tasklet_id == tasklet))
          |> NodeManager.rows_with(:node, socket.assigns.controller)

        :ok = DeadLetters.mark_seen(held, socket.assigns.current_scope.user.email)
        {:noreply, refresh(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason, "marking them seen"))}
    end
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
  def refresh_read(socket) do
    %{filter: filter, flezha_token: token} = socket.assigns
    limit = Sections.limit(socket.assigns.paging, @listing)

    fn ->
      listed = NodeManager.dlq_list(filter, token, limit: limit)

      decorated =
        case listed do
          {:ok, %{rows: entries}} -> Enum.map(entries, &decorate/1)
          {:error, _reason} -> []
        end

      %{
        listed: listed,
        decorated: decorated,
        seen: DeadLetters.seen(decorated),
        stats: DeadLetters.stats(token)
      }
    end
  end

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_apply(socket, {:ok, %{listed: {:ok, %{total: total}}} = read}) do
    %{controller: controller, show_seen?: show_seen?} = socket.assigns

    decorated =
      Enum.map(read.decorated, &%{&1 | seen?: MapSet.member?(read.seen, {&1.ref, &1.generation})})

    held = NodeManager.rows_with(decorated, :node, controller)
    shown = if show_seen?, do: held, else: Enum.reject(held, & &1.seen?)

    stats =
      read.stats |> NodeManager.ok_or([]) |> NodeManager.rows_with(:node, controller) |> merged()

    assign(socket,
      listed: decorated,
      total: total,
      entries: held,
      shown: shown,
      groups: group_by_tasklet(shown, stats),
      load_error: nil,
      stats: stats,
      unreachable: NodeManager.unreachable([read.listed, read.stats])
    )
  end

  def refresh_apply(socket, {:ok, %{listed: {:error, reason}}}), do: failed(socket, reason)
  def refresh_apply(socket, {:exit, _reason}), do: failed(socket, :read_failed)

  defp failed(socket, reason) do
    assign(socket,
      listed: [],
      total: 0,
      entries: [],
      shown: [],
      groups: [],
      stats: [],
      unreachable: [],
      load_error: reason
    )
  end

  @doc false
  def listing_grown(socket, @listing), do: refresh(socket)
  def listing_grown(socket, _id), do: socket

  # One figure per tasklet, however many controllers park its entries.
  defp merged(stats) do
    stats
    |> Enum.filter(&parked?/1)
    |> Enum.group_by(&{to_string(&1[:relay_class]), to_string(&1[:tasklet_id])})
    |> Enum.sort()
    |> Enum.map(fn {{class, tasklet}, rows} ->
      %{
        relay_class: class,
        tasklet_id: tasklet,
        entries: rows |> Enum.map(&(&1[:entries] || 0)) |> Enum.sum(),
        seen: rows |> Enum.map(&(&1[:seen] || 0)) |> Enum.sum(),
        bytes: rows |> Enum.map(&(&1[:bytes] || 0)) |> Enum.sum()
      }
    end)
  end

  @doc ~S|"2 dead letters are marked seen and hidden."|
  def hidden_seen(count, noun, plural \\ nil),
    do:
      "#{Words.count(count, noun, plural)} #{if count == 1, do: "is", else: "are"} marked seen and hidden."

  # With a durability backend, the controller keeps an emptied tasklet until
  # the tier has shipped it, and reports it at zero meanwhile.
  defp parked?(stat), do: (stat[:entries] || 0) > 0

  # Grouped the way the controllers store and ship them: one directory per
  # `{relay_class, tasklet_id}` pair. A group lists what the page `shown`
  # holds of it and counts, from the statistics, every entry its tasklet
  # parks and how many of them are seen.
  defp group_by_tasklet(shown, stats) do
    figures = Map.new(stats, &{{&1.relay_class, &1.tasklet_id}, &1})

    shown
    |> Enum.group_by(&{to_string(&1.relay_class), to_string(&1.tasklet_id)})
    |> Enum.sort()
    |> Enum.map(fn {{class, tasklet} = key, entries} ->
      figure = Map.get(figures, key, %{entries: length(entries), seen: 0})

      %{
        relay_class: class,
        tasklet_id: tasklet,
        # Oldest first within a group, as the flat listing was.
        entries: Enum.sort_by(entries, &(&1.ts_ms || 0)),
        parked: figure.entries,
        seen: figure.seen
      }
    end)
  end

  # `entry_ref` is the `class/tasklet/id` triple the controller's own verbs
  # take, so the UI addresses entries exactly as the CLI does.
  defp decorate(entry) do
    %{
      ref: DeadLetters.ref(entry),
      node: entry[:node],
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
