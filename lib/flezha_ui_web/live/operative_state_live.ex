defmodule FlezhaUiWeb.OperativeStateLive do
  @moduledoc """
  One operative's durable state: its entities, their durability counters, a
  lag series sampled at this UI's tick, and point-in-time reads.

  Beside the operative that owns them rather than as a top-level screen,
  because "what does this operative's state look like" is a question about
  that operative.

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
    {:ok,
     socket
     |> start_refresh()
     |> assign(
       ns: ns,
       operative_id: id,
       page_title: "#{id} state",
       entities: [],
       load_error: nil,
       history: %{},
       retention_hours: nil,
       selected: nil,
       travel_form: %{"kind" => "seq", "value" => ""},
       travel_result: nil,
       travel_error: nil,
       travel_target: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_event("select_entity", %{"entity" => key}, socket) do
    {:noreply, assign(socket, selected: key, travel_result: nil, travel_error: nil)}
  end

  @impl true
  def handle_event("travel_change", %{"travel" => params}, socket) do
    {:noreply, assign(socket, travel_form: Map.merge(socket.assigns.travel_form, params))}
  end

  @impl true
  def handle_event("travel", _params, socket) do
    with %{} = entity <- selected_entity(socket),
         {:ok, target} <- parse_target(socket.assigns.travel_form) do
      case NodeManager.time_travel(entity.entity_id, target) do
        {:error, reason} ->
          {:noreply,
           assign(socket, travel_result: nil, travel_error: reason, travel_target: target)}

        result ->
          {:noreply,
           assign(socket, travel_result: result, travel_error: nil, travel_target: target)}
      end
    else
      _invalid ->
        {:noreply, assign(socket, travel_error: :invalid_target, travel_result: nil)}
    end
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    class = to_string(socket.assigns.operative_id)

    case NodeManager.state_metrics() do
      {:ok, rows} ->
        entities = entities_for(rows, class)

        socket
        |> assign(
          entities: entities,
          load_error: nil,
          retention_hours: retention(class)
        )
        |> record_history(entities)

      {:error, reason} ->
        # A tick that could not be taken is a gap in the series, not a repeat
        # of the last point — so nothing is recorded for it.
        assign(socket, entities: [], load_error: reason)
    end
  end

  # The snapshot is controller-wide; a screen narrows it to the class it shows.
  defp entities_for(rows, class) do
    rows
    |> Enum.filter(fn
      {{operative_class, _procedure, _key}, _counters} -> to_string(operative_class) == class
      _other -> false
    end)
    |> Enum.map(fn {{_class, procedure, key} = entity_id, counters} ->
      %{
        entity_id: entity_id,
        key: entity_key(entity_id),
        procedure: to_string(procedure),
        entity_key: to_string(key),
        counters: counters,
        wal_gap: gap(counters)
      }
    end)
    |> Enum.sort_by(&{&1.procedure, &1.entity_key})
  end

  @doc "A stable string for an entity id, for form values and history keys."
  def entity_key({class, procedure, key}), do: "#{class}/#{procedure}/#{key}"

  # How far the WAL is ahead of the newest snapshot: the work a restart would
  # have to replay.
  defp gap(counters) do
    wal = Map.get(counters, :wal_seq)
    snapshot = Map.get(counters, :snapshot_seq)

    if is_integer(wal) and is_integer(snapshot), do: max(wal - snapshot, 0), else: nil
  end

  defp retention(class) do
    case NodeManager.workflow_retention_hours(class) do
      hours when is_number(hours) -> hours
      _unavailable -> nil
    end
  end

  # Sampled here, at this UI's tick — not a controller-recorded series, which
  # is why the chart says so.
  defp record_history(socket, entities) do
    at = System.system_time(:millisecond)

    history =
      Enum.reduce(entities, socket.assigns.history, fn entity, acc ->
        point = %{
          at: at,
          lag_ms: Map.get(entity.counters, :fsync_durability_lag_ms),
          wal_gap: entity.wal_gap
        }

        Map.update(acc, entity.key, [point], &Enum.take([point | &1], @history))
      end)

    assign(socket, history: Map.take(history, Enum.map(entities, & &1.key)))
  end

  defp selected_entity(socket) do
    Enum.find(socket.assigns.entities, &(&1.key == socket.assigns.selected))
  end

  defp parse_target(%{"kind" => kind, "value" => value}) do
    case Integer.parse(String.trim(value || "")) do
      {int, ""} when kind == "seq" -> {:ok, {:seq, int}}
      {int, ""} when kind == "timestamp" -> {:ok, {:timestamp, int}}
      _ -> :error
    end
  end

  @doc "An entity is lagging when its most recent sample carries any fsync lag."
  def lagging?(entity), do: (Map.get(entity.counters, :fsync_durability_lag_ms) || 0) > 0

  @doc """
  The controller's own reason for refusing a point-in-time read.

  The error arrives as the exception struct the controller raised; its module
  is not loadable here, so it is read as the map it is on the wire.
  """
  def travel_reason(%{message: message}) when is_binary(message), do: message
  def travel_reason(reason), do: inspect(reason)

  @doc "The resolved target, stated alongside whatever was rendered."
  def target_label({:seq, seq}), do: "sequence #{seq}"
  def target_label({:timestamp, ts}), do: "timestamp #{ts}"
  def target_label(_other), do: "—"
end
