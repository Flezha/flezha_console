defmodule FlezhaUiWeb.DlqLive do
  @moduledoc """
  Dead-letter queue: the payloads that failed and were parked.

  Replay and drop are the only destructive verbs this screen has. Both are
  confirm-gated, and replay reports whether the payload was accepted or parked
  again — a replay that immediately re-parks looks identical to a successful
  one unless the outcome is waited for.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> assign(
        page_title: "Dead-letter queue",
        filter: "",
        groups: [],
        selected: nil,
        confirm: nil,
        replay_outcome: nil
      )
      |> refresh()

    {:ok, socket}
  end

  # Holding still while a modal is open keeps a row from moving underneath the
  # operator between reading it and confirming.
  @impl FlezhaUiWeb.Live.Refresh
  def refresh_paused?(socket), do: socket.assigns.confirm != nil or socket.assigns.selected != nil

  @impl true
  def handle_info({:replay_outcome, ref}, socket) do
    outcome =
      case NodeManager.dlq_get(ref) do
        {:error, :not_found} ->
          {:replayed, ref}

        {:ok, entry, _payload} ->
          {:reparked, ref, Map.get(entry, "error")}

        {:error, reason} ->
          {:unknown, ref, reason}
      end

    {:noreply, socket |> assign(replay_outcome: outcome) |> refresh()}
  end

  @impl true
  def handle_event("filter", %{"filter" => %{"operative_class" => value}}, socket) do
    {:noreply, socket |> assign(filter: value) |> refresh()}
  end

  @impl true
  def handle_event("inspect", %{"ref" => ref}, socket) do
    case NodeManager.dlq_get(ref) do
      {:ok, entry, payload} ->
        {:noreply, assign(socket, selected: %{ref: ref, entry: entry, payload: payload})}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, dlq_error(reason))
         |> refresh()}
    end
  end

  @impl true
  def handle_event("close_inspect", _params, socket) do
    {:noreply, assign(socket, selected: nil)}
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
    case NodeManager.dlq_drop(ref) do
      :ok ->
        {:noreply,
         socket
         |> assign(confirm: nil, selected: nil)
         |> put_flash(:info, "Entry dropped. Its payload is gone.")
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm: nil)
         |> put_flash(:error, dlq_error(reason))}
    end
  end

  @impl true
  def handle_event("replay", %{"ref" => ref}, socket) do
    case NodeManager.dlq_mark_replaying(ref) do
      :ok ->
        # The outcome is only knowable after the controller's grace period:
        # until then, a re-park and a success look the same.
        Process.send_after(self(), {:replay_outcome, ref}, NodeManager.dlq_replay_grace_ms())

        {:noreply,
         socket
         |> assign(confirm: nil, replay_outcome: {:pending, ref})
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm: nil)
         |> put_flash(:error, dlq_error(reason))}
    end
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    case NodeManager.dlq_list(socket.assigns.filter) do
      {:ok, entries} ->
        decorated = Enum.map(entries, &decorate/1)

        assign(socket,
          entries: decorated,
          groups: group_by_procedure(decorated, socket.assigns.filter),
          load_error: nil,
          stats: NodeManager.ok_or(NodeManager.dlq_stats(), [])
        )

      {:error, reason} ->
        assign(socket, entries: [], groups: [], stats: [], load_error: reason)
    end
  end

  # Grouped the way the tier stores and ships them: one directory per
  # `{operative_class, procedure_id}` pair. The store is asked which pairs
  # exist so a procedure whose entries are filtered out still shows as a group
  # with a count, rather than vanishing.
  defp group_by_procedure(entries, filter) do
    parked = Enum.group_by(entries, &{&1.operative_class, &1.procedure_id})

    known =
      NodeManager.dlq_procedures(filter)
      |> NodeManager.ok_or([])
      |> Enum.map(fn {class, procedure} -> {to_string(class), to_string(procedure)} end)

    (known ++ Map.keys(parked))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {class, procedure} = key ->
      group_entries = Map.get(parked, key, [])

      %{
        operative_class: class,
        procedure_id: procedure,
        # Oldest first within a group, as the flat listing was.
        entries: Enum.sort_by(group_entries, &(&1.age_s || 0), :desc),
        parked: length(group_entries)
      }
    end)
    |> Enum.reject(&(&1.parked == 0 and &1.entries == []))
  end

  # `entry_ref` is the `class/procedure/id` triple the controller's own verbs
  # take, so the UI addresses entries exactly as the CLI does.
  defp decorate(entry) do
    %{
      ref: "#{entry["operative_class"]}/#{entry["procedure_id"]}/#{entry["id"]}",
      operative_class: entry["operative_class"],
      procedure_id: entry["procedure_id"],
      entity_key: entry["entity_key"],
      channel: entry["channel"],
      generation: entry["generation"] || 1,
      age_s: age_seconds(entry["ts_ms"]),
      error: entry["error"]
    }
  end

  defp age_seconds(nil), do: nil
  defp age_seconds(ts_ms), do: div(System.system_time(:millisecond) - ts_ms, 1000)

  defp dlq_error(:not_found), do: "That entry is no longer in the queue."
  defp dlq_error(:bad_entry_ref), do: "Malformed entry reference."

  defp dlq_error(:payload_not_replayable),
    do: "This entry's payload cannot be replayed."

  defp dlq_error(:operative_not_running),
    do: "The operative that owns this entry is not running."

  defp dlq_error(reason), do: "Dead-letter queue error: #{inspect(reason)}"
end
