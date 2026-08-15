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
        assign(socket,
          entries: Enum.map(entries, &decorate/1),
          load_error: nil,
          stats: NodeManager.ok_or(NodeManager.dlq_stats(), [])
        )

      {:error, reason} ->
        assign(socket, entries: [], stats: [], load_error: reason)
    end
  end

  # `entry_ref` is the `class/procedure/id` triple the controller's own verbs
  # take, so the UI addresses entries exactly as the CLI does.
  defp decorate(entry) do
    %{
      ref: "#{entry["operative_class"]}/#{entry["procedure_id"]}/#{entry["id"]}",
      operative_class: entry["operative_class"],
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
