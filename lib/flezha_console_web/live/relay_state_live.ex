defmodule FlezhaConsoleWeb.RelayStateLive do
  @moduledoc """
  A relay's State view: what it has kept. For a steps relay its steps facts
  as sentences, and for a durable one its task journal and input log; its SDK
  cell state on request; and its durable cells with their durability
  counters, a lag series sampled at this UI's tick, and point-in-time reads.

  Beside the relay that owns them rather than as a top-level screen, because
  "what does this relay's state look like" is a question about that relay.

  It also maintains them: a selected cell shows its outbox, a flow relay's cell
  is replayed from a point in its history, a cell is rotated or deleted, and
  the class's history retention is set. Every change asks first, naming the
  cell; deleting says it cannot be undone.
  """

  use FlezhaConsoleWeb, :live_view

  use FlezhaConsoleWeb.Live.Refresh, every: 5_000

  use FlezhaConsoleWeb.Live.Sections,
    open: %{"journal" => false, "input-log" => false, "sdk-state" => false}

  alias FlezhaConsole.Service.NodeManager

  # Enough points to see a trend at the tick rate without unbounded growth.
  @history 60

  @impl true
  def mount(%{"ns" => ns, "id" => id}, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> sections_init()
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
        travel_target: nil,
        history_retention: nil,
        retention_form: %{"hours" => ""},
        retention_error: nil,
        outbox: nil,
        outbox_error: nil,
        confirm: nil,
        replayed: nil,
        facts: nil,
        journal: nil,
        committed_iterations: [],
        input_log: nil,
        inbox: nil,
        inbox_error: nil,
        rewind_target: nil,
        state_json: nil,
        state_seq: nil,
        state_notice: nil,
        selector_form: %{"tasklet" => "", "cell_key" => ""},
        auto_refresh_state: false
      )

    # Read once, on the connected mount: it resolves the whole namespace.
    partitions =
      if connected?(socket),
        do: NodeManager.relay_partitions(ns, id, socket.assigns[:flezha_token]),
        else: []

    socket = assign(socket, partitions: partitions)

    {:ok, refresh(socket)}
  end

  # Read until it answers: one refused read must not hide the steps sections
  # for as long as the screen is open.
  defp read_relay(%{assigns: %{facts: nil}} = socket),
    do: socket |> assign_relay() |> load_retention()

  defp read_relay(socket), do: socket

  # Cells are filed under the relay's class, which defaults to its id. A
  # finished relay has no overwatch to ask: its class is then its id and its
  # run unknown, so nothing that needs a live relay is offered.
  defp assign_relay(socket) do
    %{ns: ns, relay_id: id, flezha_token: token} = socket.assigns

    case NodeManager.overwatch_facts(ns, id, token) do
      {:ok, %{relay_class: class, run: run} = facts} when is_binary(class) ->
        assign(socket, relay_class: class, run: run, facts: facts)

      _unreadable ->
        assign(socket, relay_class: id, run: nil, facts: nil)
    end
  end

  # How long a finished instance is kept applies to a steps relay alone. A
  # relay with no overwatch to ask is a finished one, which only a steps relay
  # can be.
  defp load_retention(%{assigns: %{run: run}} = socket) when run in [:steps, nil] do
    %{relay_class: class, flezha_token: token} = socket.assigns

    case NodeManager.completed_retention_hours(class, %{}, token) do
      {:ok, hours} when is_number(hours) -> assign(socket, retention_hours: hours)
      _unavailable -> assign(socket, retention_hours: nil)
    end
  end

  defp load_retention(socket), do: assign(socket, retention_hours: nil)

  # A row could move underneath an open confirmation.
  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_paused?(socket),
    do: socket.assigns.confirm != nil or socket.assigns.rewind_target != nil

  @impl true
  def handle_event("fetch_state", _params, socket) do
    {:noreply, fetch_state(socket)}
  end

  @impl true
  def handle_event("selector_change", %{"selector" => params}, socket) do
    {:noreply, assign(socket, selector_form: Map.merge(socket.assigns.selector_form, params))}
  end

  @impl true
  def handle_event("toggle_auto_refresh", _params, socket) do
    {:noreply, assign(socket, auto_refresh_state: !socket.assigns.auto_refresh_state)}
  end

  @impl true
  def handle_event("open_rewind", _params, socket) do
    {:noreply, assign(socket, rewind_target: List.first(socket.assigns.committed_iterations))}
  end

  @impl true
  def handle_event("cancel_rewind", _params, socket) do
    {:noreply, assign(socket, rewind_target: nil)}
  end

  @impl true
  def handle_event("select_rewind", %{"rewind" => %{"iteration" => value}}, socket) do
    {:noreply, assign(socket, rewind_target: parse_iteration(value))}
  end

  @impl true
  def handle_event("rewind", _params, socket) do
    %{ns: ns, relay_class: class, rewind_target: target, flezha_token: token} = socket.assigns

    # Only an iteration the journal reported as committed is ever a target, so
    # a stale form cannot ask for one the controller would refuse.
    if target in socket.assigns.committed_iterations do
      case NodeManager.rewind(ns, class, target, token) do
        {:error, reason} ->
          {:noreply,
           socket
           |> assign(rewind_target: nil)
           |> put_flash(:error, error_message(reason, "the rewind"))}

        _ok ->
          {:noreply,
           socket
           |> assign(rewind_target: nil)
           |> load_durability()
           |> put_flash(:info, "Rewound to iteration #{target}.")}
      end
    else
      {:noreply, assign(socket, rewind_target: nil)}
    end
  end

  @impl true
  def handle_event("select_cell", %{"cell" => key}, socket) do
    {:noreply,
     socket
     |> assign(selected: key, travel_result: nil, travel_error: nil, replayed: nil)
     |> load_outbox()}
  end

  # Rotate, delete and replay each ask first; the confirmation names the cell.
  @impl true
  def handle_event("confirm", %{"action" => action, "cell" => cell}, socket)
      when action in ~w(rotate delete replay) do
    {:noreply, assign(socket, confirm: %{action: action, cell: cell})}
  end

  @impl true
  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, confirm: nil)}
  end

  @impl true
  def handle_event("rotate", %{"cell" => cell}, socket) do
    socket = assign(socket, confirm: nil)

    case NodeManager.rotate_cell(cell, socket.assigns.flezha_token) do
      {:ok, _answer} ->
        {:noreply, put_flash(socket, :info, "Compaction requested for #{cell}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason, "the rotation"))}
    end
  end

  @impl true
  def handle_event("delete", %{"cell" => cell}, socket) do
    socket = assign(socket, confirm: nil)

    case NodeManager.delete_cell(cell, socket.assigns.flezha_token) do
      {:ok, _answer} ->
        {:noreply,
         socket
         |> assign(
           selected: if(socket.assigns.selected == cell, do: nil, else: socket.assigns.selected)
         )
         |> refresh()
         |> put_flash(:info, "Persisted state of #{cell} deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason, "the delete"))}
    end
  end

  # Replay reuses time travel's target: the same sequence or ISO 8601 time.
  @impl true
  def handle_event("replay", %{"cell" => cell}, socket) do
    socket = assign(socket, confirm: nil)

    with {:ok, target} <- parse_target(socket.assigns.travel_form) do
      case NodeManager.replay_cell(socket.assigns.ns, cell, target, socket.assigns.flezha_token) do
        {:ok, replayed} -> {:noreply, assign(socket, replayed: replayed, travel_error: nil)}
        {:error, reason} -> {:noreply, assign(socket, replayed: nil, travel_error: reason)}
      end
    else
      :error -> {:noreply, assign(socket, replayed: nil, travel_error: :invalid_target)}
    end
  end

  @impl true
  def handle_event("retention_change", %{"retention" => params}, socket) do
    {:noreply, assign(socket, retention_form: Map.merge(socket.assigns.retention_form, params))}
  end

  @impl true
  def handle_event("set_retention", %{"retention" => params}, socket) do
    %{relay_class: class, flezha_token: token} = socket.assigns
    form = Map.merge(socket.assigns.retention_form, params)

    case Integer.parse(String.trim(form["hours"] || "")) do
      {hours, ""} when hours >= 0 ->
        case NodeManager.set_retention(class, hours, token) do
          {:ok, %{hours: set}} ->
            {:noreply,
             socket
             |> assign(
               retention_form: %{"hours" => ""},
               retention_error: nil,
               history_retention: set
             )
             |> put_flash(
               :info,
               "History retention set to #{set} hours until the controller next boots."
             )}

          {:error, reason} ->
            {:noreply, assign(socket, retention_form: form, retention_error: reason)}
        end

      _invalid ->
        {:noreply,
         assign(socket,
           retention_form: form,
           retention_error: "Hours must be a whole number of zero or more."
         )}
    end
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

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh(socket) do
    socket
    |> read_relay()
    |> load_cells()
    |> load_durability()
    |> then(&if(&1.assigns.auto_refresh_state, do: fetch_state(&1), else: &1))
  end

  # The retained records, read when the input log section opens, never on the
  # tick; payloads are never read.
  def section_opened(socket, "input-log"), do: load_inbox(socket)
  def section_opened(socket, _key), do: socket

  defp load_inbox(%{assigns: %{input_log: nil}} = socket), do: socket

  defp load_inbox(socket) do
    case NodeManager.inbox(socket.assigns.relay_id, socket.assigns.flezha_token) do
      {:ok, inbox} -> assign(socket, inbox: inbox, inbox_error: nil)
      {:error, reason} -> assign(socket, inbox: nil, inbox_error: reason)
    end
  end

  # The task journal and input log exist only for a durable steps relay.
  # Reading them for a flow relay would answer empty, which renders as "there
  # is nothing here" rather than "this does not apply".
  defp load_durability(%{assigns: %{facts: %{run: :steps, durable_steps: true}}} = socket) do
    %{relay_id: id, flezha_token: token} = socket.assigns

    assign(socket,
      journal: NodeManager.ok_or(NodeManager.task_journal(id, token), nil),
      committed_iterations:
        id |> NodeManager.committed_iterations(token) |> NodeManager.ok_or([]) |> Enum.sort(:desc),
      input_log: %{
        undelivered: length(NodeManager.ok_or(NodeManager.input_log_undelivered(id, token), [])),
        last_offset: integer_or_nil(NodeManager.input_log_last_offset(id, token)),
        consumed_offset: integer_or_nil(NodeManager.consumed_offset(id, token))
      }
    )
  end

  defp load_durability(socket) do
    assign(socket, journal: nil, committed_iterations: [], input_log: nil)
  end

  defp integer_or_nil({:ok, value}) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp fetch_state(socket) do
    %{ns: ns, relay_id: id, selector_form: form, flezha_token: token} = socket.assigns

    with {:ok, cell} <- selector(form),
         {:ok, json, change_seq} <- NodeManager.cell_state(ns, id, cell, token) do
      assign(socket, state_json: json, state_seq: change_seq, state_notice: nil)
    else
      {:error, reason} ->
        assign(socket, state_json: nil, state_seq: nil, state_notice: state_notice(reason))
    end
  end

  # No tasklet reads every cell; a tasklet alone narrows to its cells; both
  # narrow to one cell. A cell key is unique only within its tasklet, so it is
  # never sent alone.
  defp selector(form) do
    tasklet = String.trim(form["tasklet"] || "")
    cell_key = String.trim(form["cell_key"] || "")

    cond do
      tasklet == "" and cell_key != "" -> {:error, :cell_key_without_tasklet}
      tasklet == "" -> {:ok, nil}
      cell_key == "" -> {:ok, tasklet}
      true -> {:ok, "#{tasklet}/#{cell_key}"}
    end
  end

  # These are explanations, not failures: the relay is healthy, the state just
  # is not there to read.
  defp state_notice(:cell_key_without_tasklet),
    do: {:info, "A cell key is unique only within its tasklet, so name the tasklet too."}

  defp state_notice(reason) do
    case NodeManager.error(reason) do
      %{code: "state.persistence_off"} ->
        {:info, "This relay declares persistence off, so it keeps no cell state to read."}

      %{code: "state.not_resident", message: message} ->
        {:info, "#{message} This relay's cells are not held in memory."}

      _failure ->
        {:error, reason}
    end
  end

  defp parse_iteration(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  @doc """
  A steps relay's facts as sentences: durability, delivery, the correction
  window, how it arrived, suspension and an initialisation failure.
  """
  def steps_sentences(facts) do
    [
      if(facts.durable_steps,
        do: {"steps-durable", "It is durable: its steps are journaled and survive a restart."},
        else: {"steps-durable", "It is not durable: its steps are not journaled."}
      ),
      if(facts.effectively_once,
        do: {nil, "Each input takes effect exactly once."},
        else: {nil, "Inputs are delivered at least once."}
      ),
      facts.correction_window_ms &&
        {"steps-correction-window",
         "Late corrections are accepted for #{Format.duration(facts.correction_window_ms)}."},
      facts.arrived_via_hotswap? && {nil, "It arrived on this runner through a hot swap."},
      facts.suspended && {nil, "It is suspended at a committed boundary."}
    ]
    |> Enum.filter(& &1)
  end

  @doc "The task journal's digest: how many iterations are committed, and the latest."
  def journal_digest(nil, _committed), do: nil
  def journal_digest(_journal, []), do: "nothing committed yet"

  def journal_digest(_journal, [latest | _] = committed),
    do: "#{Words.count(length(committed), "iteration")} committed, latest #{latest}"

  # The controller answers `-1` for an input log that holds no records.
  defp last_offset(-1), do: "no records"
  defp last_offset(nil), do: "—"
  defp last_offset(offset), do: offset

  defp load_cells(socket) do
    case NodeManager.cells(socket.assigns.relay_class, socket.assigns.flezha_token) do
      {:ok, %{cells: rows} = answer} ->
        cells = rows |> Enum.map(&decorate/1) |> Enum.sort_by(&{&1.tasklet, &1.cell_key})

        # An older controller answers no retention: stated as unknown, never
        # left out.
        socket
        |> assign(
          cells: cells,
          load_error: nil,
          history_retention: Map.get(answer, :history_retention_hours, :unknown)
        )
        |> record_history(cells)

      {:error, reason} ->
        # A tick that could not be taken is a gap in the series, not a repeat
        # of the last point — so nothing is recorded for it.
        assign(socket, cells: [], load_error: reason, history_retention: nil)
    end
  end

  # Read when a cell is selected, never on the tick.
  defp load_outbox(socket) do
    case NodeManager.outbox(socket.assigns.selected, socket.assigns.flezha_token) do
      {:ok, outbox} -> assign(socket, outbox: outbox, outbox_error: nil)
      {:error, reason} -> assign(socket, outbox: nil, outbox_error: reason)
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

  defp confirm_title("rotate"), do: "Rotate cell state?"
  defp confirm_title("delete"), do: "Delete cell state?"
  defp confirm_title("replay"), do: "Replay cell?"

  defp confirm_label("rotate"), do: "Rotate"
  defp confirm_label("delete"), do: "Delete"
  defp confirm_label("replay"), do: "Replay"

  defp confirm_variant("rotate"), do: "primary"
  defp confirm_variant(_action), do: "danger"

  @doc """
  A cell is lagging while its newest fsync lag, of `samples` newest first, is
  above a second and higher than the sample before: a few milliseconds is a
  disk's normal pace.
  """
  def lagging?([%{lag_ms: now}, %{lag_ms: before} | _older])
      when is_integer(now) and is_integer(before),
      do: now > 1_000 and now > before

  def lagging?(_samples), do: false

  @doc "Why a point-in-time read was not made or was refused."
  def travel_reason(:invalid_target),
    do: "The target must be a whole sequence number or an ISO 8601 time."

  def travel_reason(reason), do: error_message(reason)
end
