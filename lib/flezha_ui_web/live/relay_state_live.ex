defmodule FlezhaUiWeb.RelayStateLive do
  @moduledoc """
  One relay's durable state: its cells, their durability counters, a lag
  series sampled at this UI's tick, and point-in-time reads.

  Beside the relay that owns them rather than as a top-level screen, because
  "what does this relay's state look like" is a question about that relay.

  Reads only. `state delete` and `state rotate` stay `flz` verbs: a browser is
  the wrong place for a decision that cannot be undone from the same browser.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000

  alias FlezhaUi.Service.NodeManager

  # Enough points to see a trend at the tick rate without unbounded growth.
  @history 60

  @impl true
  def mount(%{"ns" => ns, "id" => id}, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> assign(
        ns: ns,
        relay_id: id,
        page_title: "#{id} state",
        cells: [],
        load_error: nil,
        history: %{},
        retention_hours: nil,
        selected: nil,
        travel_form: %{"kind" => "seq", "value" => ""},
        travel_result: nil,
        travel_error: nil,
        travel_target: nil
      )

    {:ok, socket |> assign(relay_class: relay_class(socket)) |> load_retention() |> refresh()}
  end

  # Cells are filed under the relay's class, which defaults to its id. A
  # finished relay has no overwatch to ask, and its class is then its id.
  defp relay_class(socket) do
    %{ns: ns, relay_id: id, flezha_token: token} = socket.assigns

    case NodeManager.overwatch_facts(ns, id, token) do
      {:ok, %{relay_class: class}} when is_binary(class) -> class
      _unreadable -> id
    end
  end

  defp load_retention(socket) do
    %{relay_class: class, flezha_token: token} = socket.assigns

    case NodeManager.completed_retention_hours(class, %{}, token) do
      {:ok, hours} when is_number(hours) -> assign(socket, retention_hours: hours)
      _unavailable -> assign(socket, retention_hours: nil)
    end
  end

  @impl true
  def handle_event("select_cell", %{"cell" => key}, socket) do
    {:noreply, assign(socket, selected: key, travel_result: nil, travel_error: nil)}
  end

  @impl true
  def handle_event("travel_change", %{"travel" => params}, socket) do
    {:noreply, assign(socket, travel_form: Map.merge(socket.assigns.travel_form, params))}
  end

  @impl true
  def handle_event("travel", _params, socket) do
    with %{} = cell <- selected_cell(socket),
         {:ok, target} <- parse_target(socket.assigns.travel_form) do
      case NodeManager.time_travel(cell.key, target, socket.assigns.flezha_token) do
        {:ok, result} ->
          {:noreply,
           assign(socket, travel_result: result, travel_error: nil, travel_target: target)}

        {:error, reason} ->
          {:noreply,
           assign(socket, travel_result: nil, travel_error: reason, travel_target: target)}
      end
    else
      _invalid ->
        {:noreply, assign(socket, travel_error: :invalid_target, travel_result: nil)}
    end
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    case NodeManager.cells(socket.assigns.relay_class, socket.assigns.flezha_token) do
      {:ok, %{cells: rows}} ->
        cells = rows |> Enum.map(&decorate/1) |> Enum.sort_by(&{&1.tasklet, &1.cell_key})

        socket
        |> assign(cells: cells, load_error: nil)
        |> record_history(cells)

      {:error, reason} ->
        # A tick that could not be taken is a gap in the series, not a repeat
        # of the last point — so nothing is recorded for it.
        assign(socket, cells: [], load_error: reason)
    end
  end

  defp decorate(row) do
    %{
      key: "#{row.relay_class}/#{row.tasklet_id}/#{row.cell_key}",
      tasklet: to_string(row.tasklet_id),
      cell_key: to_string(row.cell_key),
      counters: row,
      wal_gap: gap(row)
    }
  end

  # How far the WAL is ahead of the newest snapshot: the work a restart would
  # have to replay.
  defp gap(counters) do
    wal = Map.get(counters, :wal_seq)
    snapshot = Map.get(counters, :snapshot_seq)

    if is_integer(wal) and is_integer(snapshot), do: max(wal - snapshot, 0), else: nil
  end

  # Sampled here, at this UI's tick — not a controller-recorded series, which
  # is why the chart says so.
  defp record_history(socket, cells) do
    at = System.system_time(:millisecond)

    history =
      Enum.reduce(cells, socket.assigns.history, fn cell, acc ->
        point = %{
          at: at,
          lag_ms: Map.get(cell.counters, :fsync_durability_lag_ms),
          wal_gap: cell.wal_gap
        }

        Map.update(acc, cell.key, [point], &Enum.take([point | &1], @history))
      end)

    assign(socket, history: Map.take(history, Enum.map(cells, & &1.key)))
  end

  defp selected_cell(socket) do
    Enum.find(socket.assigns.cells, &(&1.key == socket.assigns.selected))
  end

  # A whole number is a sequence; anything else must be an ISO 8601 time,
  # which is how the controller takes a time.
  defp parse_target(%{"kind" => kind, "value" => value}) do
    value = String.trim(value || "")

    case {kind, Integer.parse(value), DateTime.from_iso8601(value)} do
      {"seq", {seq, ""}, _} when seq >= 0 -> {:ok, Integer.to_string(seq)}
      {"time", _, {:ok, _dt, _offset}} -> {:ok, value}
      _invalid -> :error
    end
  end

  @doc "A cell is lagging when its most recent sample carries any fsync lag."
  def lagging?(cell), do: (Map.get(cell.counters, :fsync_durability_lag_ms) || 0) > 0

  @doc "Why a point-in-time read was not made or was refused."
  def travel_reason(:invalid_target),
    do: "The target must be a whole sequence number or an ISO 8601 time."

  def travel_reason(reason), do: error_message(reason)
end
