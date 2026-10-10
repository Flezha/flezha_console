defmodule FlezhaUiWeb.RelayLive do
  use FlezhaUiWeb, :live_view

  # The pipeline graph reads its rates from snapshot deltas, so this screen
  # ticks whether or not the operator armed the cell-state panel. A runner
  # flip is the one state change worth showing before the next tick.
  use FlezhaUiWeb.Live.Refresh,
    every: 2_000,
    on_events: [:runner_connected, :runner_disconnected]

  use FlezhaUiWeb.Topology
  use FlezhaUiWeb.Live.PluginForm

  # The graph and the relay's own facts are what the screen is for; the API,
  # the calls, the task journal, the input log, the SDK state and the bindings
  # are what an operator goes looking for, so they start folded away.
  use FlezhaUiWeb.Live.Sections,
    open: %{
      "api" => false,
      "calls" => false,
      "journal" => false,
      "input-log" => false,
      "sdk-state" => false,
      "plugins" => false
    }

  alias FlezhaUi.Format
  alias FlezhaUi.Service.EventFeed
  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Live.TypedFields
  alias FlezhaUiWeb.Topology

  @impl true
  def mount(%{"ns" => ns, "id" => id}, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> Topology.init()
      |> sections_init()
      |> plugin_form_init()
      |> assign(
        ns: ns,
        relay_id: id,
        page_title: id,
        state_json: nil,
        state_seq: nil,
        state_notice: nil,
        load_error: nil,
        selector_form: %{"tasklet" => "", "cell_key" => ""},
        auto_refresh_state: false,
        confirm_stop: false,
        confirm_unbind: nil,
        idle_bindings: [],
        rewind_target: nil,
        completion: nil,
        journal: nil,
        committed_iterations: [],
        input_log: nil,
        inbox: nil,
        inbox_error: nil,
        tap: nil,
        diagnosis: nil,
        diagnosis_error: nil,
        api: [],
        api_error: nil,
        calls: nil,
        talk: nil,
        talk_results: []
      )
      |> load_data()
      |> load_completion()
      |> load_api()
      |> Topology.load_pipeline()

    {:ok, socket}
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    socket
    |> maybe_fetch_state()
    |> load_data()
    |> Topology.load_pipeline()
  end

  # The cell-state panel reloads only when the operator armed it; the graph
  # ticks regardless, because a rate needs two snapshots to exist at all.
  defp maybe_fetch_state(socket) do
    if socket.assigns.auto_refresh_state, do: fetch_state(socket), else: socket
  end

  # ---- Payload tap ----
  #
  # A listen on the relay's input or output, held by a feed linked to this
  # screen: closing the tap or leaving the page stops the feed, which ends the
  # listen on the controller.

  @impl true
  def handle_event("graph_tap", %{"direction" => direction}, socket)
      when direction in ~w(input output) do
    socket = close_tap(socket)

    {:noreply,
     assign(socket,
       tap: %{
         direction: direction,
         feed: listen_feed(socket, String.to_existing_atom(direction), :payload_tap),
         started_at: System.monotonic_time(:millisecond),
         count: 0,
         bytes: 0,
         recent: [],
         error: nil,
         ended?: false
       }
     )}
  end

  @impl true
  def handle_event("graph_tap_close", _params, socket) do
    {:noreply, close_tap(socket)}
  end

  # Only an open panel listens, whatever the client sends.
  @impl true
  def handle_event("calls_reopen", _params, socket) do
    if socket.assigns.sections["calls"],
      do: {:noreply, open_calls(socket)},
      else: {:noreply, socket}
  end

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
           |> load_data()
           |> put_flash(:info, "Rewound to iteration #{target}.")}
      end
    else
      {:noreply, assign(socket, rewind_target: nil)}
    end
  end

  @impl true
  def handle_event("confirm_stop", _params, socket) do
    {:noreply, assign(socket, confirm_stop: true)}
  end

  @impl true
  def handle_event("cancel_stop", _params, socket) do
    {:noreply, assign(socket, confirm_stop: false)}
  end

  @impl true
  def handle_event("stop_relay", _params, socket) do
    %{ns: ns, relay_id: id, flezha_token: token} = socket.assigns

    case NodeManager.stop_relay(ns, id, token) do
      {:ok, answer} ->
        {:noreply,
         socket
         |> put_flash(:info, Format.relay_stopped(id, answer))
         |> push_navigate(to: ~p"/namespaces/#{ns}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_stop: false)
         |> put_flash(:error, error_message(reason, "the stop"))}
    end
  end

  @impl true
  def handle_event("confirm_unbind", %{"plugin_id" => plugin_id}, socket) do
    {:noreply, assign(socket, confirm_unbind: plugin_id)}
  end

  @impl true
  def handle_event("cancel_unbind", _params, socket) do
    {:noreply, assign(socket, confirm_unbind: nil)}
  end

  # Unbinds this relay alone, which also clears a binding whose plugin was
  # disabled: a disabled plugin keeps its bindings and can no longer be
  # disabled again.
  @impl true
  def handle_event("unbind_plugin", %{"plugin_id" => plugin_id}, socket) do
    %{ns: ns, relay_id: relay_id, flezha_token: token} = socket.assigns

    case NodeManager.unbind_plugin(plugin_id, ns, relay_id, token) do
      :ok ->
        {:noreply,
         socket
         |> assign(confirm_unbind: nil)
         |> load_data()
         |> put_flash(:info, "#{relay_id} unbound from plugin #{plugin_id}.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_unbind: nil)
         |> put_flash(:error, error_message(reason, "the unbind"))}
    end
  end

  # ---- Diagnosis ----
  #
  # On request only: the controller reads verdicts, runners, dead letters and
  # the input log to answer it, so it never rides the tick.

  @impl true
  def handle_event("diagnose", _params, socket) do
    %{ns: ns, relay_id: id, flezha_token: token} = socket.assigns

    case NodeManager.diagnose_relay(ns, id, token) do
      {:ok, diagnosis} -> {:noreply, assign(socket, diagnosis: diagnosis, diagnosis_error: nil)}
      {:error, reason} -> {:noreply, assign(socket, diagnosis: nil, diagnosis_error: reason)}
    end
  end

  # ---- Talking to the relay ----
  #
  # One dialog sends to the relay, calls it, or calls an entry channel its API
  # announces. A call waits for the relay's answer, so it runs as an async
  # task: the screen keeps refreshing, and closing the dialog cancels the wait.

  @impl true
  def handle_event("talk_open", _params, socket) do
    mode = if api_channels(socket.assigns.api) == [], do: :raw, else: :channel

    talk = %{
      mode: mode,
      channel: socket.assigns.api |> api_channels() |> List.first(),
      fields: %{
        "payload" => "",
        "channel" => "",
        "key" => "",
        "msg_id" => "",
        "deadline_ms" => "30000",
        "json" => "",
        "value" => %{}
      },
      error: nil,
      field_errors: [],
      waiting: nil
    }

    {:noreply, assign(socket, talk: talk)}
  end

  @impl true
  def handle_event("talk_close", _params, socket) do
    {:noreply, socket |> cancel_async(:talk) |> assign(talk: nil)}
  end

  def handle_event(event, _params, %{assigns: %{talk: nil}} = socket)
      when event in ~w(talk_mode talk_change talk_submit),
      do: {:noreply, socket}

  @impl true
  def handle_event("talk_mode", %{"mode" => mode}, socket) when mode in ~w(channel raw) do
    {:noreply, update(socket, :talk, &%{&1 | mode: String.to_existing_atom(mode), error: nil})}
  end

  @impl true
  def handle_event("talk_change", %{"talk" => params}, socket) do
    {:noreply, update(socket, :talk, &talk_change(&1, params, socket.assigns.api))}
  end

  @impl true
  def handle_event(
        "talk_submit",
        %{"talk" => params},
        %{assigns: %{talk: %{waiting: nil}}} = socket
      ) do
    talk = %{talk_change(socket.assigns.talk, params, socket.assigns.api) | field_errors: []}
    %{ns: ns, relay_id: id, flezha_token: token} = socket.assigns

    case talk_request(talk, params["action"], {ns, id, token}) do
      {:ok, kind, call} ->
        {:noreply,
         socket
         |> assign(talk: %{talk | waiting: kind, error: nil})
         |> start_async(:talk, fn -> {kind, call.()} end)}

      {:error, {:fields, errors}} ->
        {:noreply, assign(socket, talk: %{talk | field_errors: errors})}

      {:error, message} ->
        {:noreply, assign(socket, talk: %{talk | error: message})}
    end
  end

  # One request at a time: a second submit while the first waits is dropped.
  def handle_event("talk_submit", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:talk, _result, %{assigns: %{talk: nil}} = socket), do: {:noreply, socket}

  def handle_async(:talk, {:ok, {kind, {:ok, answer}}}, socket) do
    {:noreply, talk_result(socket, %{kind: kind, answer: answer})}
  end

  def handle_async(:talk, {:ok, {kind, {:error, reason}}}, socket) do
    {:noreply, talk_result(socket, %{kind: kind, error: reason})}
  end

  def handle_async(:talk, {:exit, reason}, socket) do
    {:noreply,
     talk_result(socket, %{kind: socket.assigns.talk.waiting, error: {:remote_error, reason}})}
  end

  # Kept outside `@talk`, so closing the dialog keeps this session's results.
  @talk_results_max 10

  defp talk_result(socket, result) do
    result = Map.put(result, :at, DateTime.utc_now())

    socket
    |> update(:talk, &%{&1 | waiting: nil})
    |> update(:talk_results, &Enum.take([result | &1], @talk_results_max))
  end

  # ---- Calls ----
  #
  # A listen on the relay's calls, held by a feed linked to this screen while
  # the Calls section is open: folding it or leaving the page ends the listen.
  # Core audits every listen, so none is held while nobody looks.

  def section_opened(socket, "api"), do: load_api(socket)
  def section_opened(socket, "input-log"), do: load_inbox(socket)
  def section_opened(socket, "calls"), do: open_calls(socket)
  def section_opened(socket, "plugins"), do: assign_idle_bindings(socket)
  def section_opened(socket, _key), do: socket

  def section_closed(socket, "calls"), do: close_calls(socket)
  def section_closed(socket, _key), do: socket

  @impl true
  def handle_info({kind, :payload_tap, event}, %{assigns: %{tap: %{} = tap}} = socket) do
    {:noreply, assign(socket, tap: tap_event(tap, kind, event))}
  end

  @impl true
  def handle_info({kind, :call_activity, event}, %{assigns: %{calls: %{} = calls}} = socket) do
    {:noreply, assign(socket, calls: call_event(calls, kind, event))}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp tap_event(tap, :feed_event, {kind, payload, meta}) when kind in [:output, :input, :part] do
    frame = Format.frame(payload, meta)

    %{
      tap
      | count: tap.count + 1,
        bytes: tap.bytes + frame.bytes,
        recent: Enum.take([frame | tap.recent], 5)
    }
  end

  # Either way the feed has stopped, so the tap is no longer live.
  defp tap_event(tap, :feed_error, reason), do: %{tap | error: reason, feed: nil}
  defp tap_event(tap, :feed_ended, _answer), do: %{tap | ended?: true, feed: nil}
  defp tap_event(tap, _kind, _event), do: tap

  defp close_tap(%{assigns: %{tap: nil}} = socket), do: socket

  defp close_tap(%{assigns: %{tap: tap}} = socket) do
    EventFeed.stop(tap.feed, :payload_tap)
    assign(socket, tap: nil)
  end

  defp listen_feed(socket, direction, tag) do
    %{ns: ns, relay_id: id, flezha_token: token} = socket.assigns
    EventFeed.listen(ns, id, direction, token, tag)
  end

  # The listed calls outlive the listen: reopening goes on listing above them.
  defp open_calls(socket) do
    if NodeManager.granted?(socket.assigns.operations, "Relay.listen") do
      socket = close_calls(socket)
      feed = listen_feed(socket, :calls, :call_activity)
      calls = socket.assigns.calls || %{entries: [], seq: 0}

      assign(socket,
        calls: Map.merge(calls, %{feed: feed, attached?: false, error: nil, ended?: false})
      )
    else
      socket
    end
  end

  defp close_calls(%{assigns: %{calls: %{feed: feed} = calls}} = socket) when is_pid(feed) do
    EventFeed.stop(feed, :call_activity)
    assign(socket, calls: stopped(calls))
  end

  defp close_calls(socket), do: socket

  @calls_max 50
  @call_payload_chars 500

  # The per-panel `seq`, not the call id, names a row: a relay's call retried
  # by its delivery repeats its id.
  defp call_event(calls, :feed_event, {:call, payload, meta}) do
    entry = %{
      seq: calls.seq + 1,
      call_id: meta["flz.call_id"],
      source: meta["flz.call_source"],
      caller: meta["flz.call_caller"],
      channel: meta["channel"],
      payload: call_payload(payload),
      at: call_at(meta["flz.call_at"]),
      outcome: nil
    }

    %{calls | seq: entry.seq, entries: Enum.take([entry | calls.entries], @calls_max)}
  end

  # An outcome completes the newest waiting call of its id. One whose call is
  # not listed was taken before the panel opened, or has left the list.
  defp call_event(calls, :feed_event, {kind, value, meta})
       when kind in [:answered, :timed_out, :refused] do
    id = meta["flz.call_id"]

    case Enum.find_index(calls.entries, &(&1.call_id == id and is_nil(&1.outcome))) do
      nil ->
        calls

      index ->
        outcome = call_outcome(kind, value, meta)
        %{calls | entries: List.update_at(calls.entries, index, &%{&1 | outcome: outcome})}
    end
  end

  defp call_event(calls, :feed_event, :attached), do: %{calls | attached?: true}
  defp call_event(calls, :feed_error, reason), do: %{stopped(calls) | error: reason}
  defp call_event(calls, :feed_ended, _answer), do: %{stopped(calls) | ended?: true}
  defp call_event(calls, _kind, _event), do: calls

  # A call still waiting when its listen stops can no longer hear its outcome,
  # and a later listen may miss it, so it stays unheard.
  defp stopped(calls) do
    unheard = %{kind: :not_heard, channel: nil, payload: nil, error: nil, duration_ms: nil}
    entries = Enum.map(calls.entries, &if(&1.outcome, do: &1, else: %{&1 | outcome: unheard}))
    %{calls | feed: nil, attached?: false, entries: entries}
  end

  # An answer carries its payload; a timeout or a refusal, its error.
  defp call_outcome(kind, value, meta) do
    %{
      kind: kind,
      channel: meta["channel"],
      payload: if(kind == :answered, do: call_payload(value)),
      error: if(kind != :answered, do: value),
      duration_ms: meta["flz.call_duration_ms"]
    }
  end

  # Bounded, so a busy relay's large payloads do not grow the screen's memory.
  defp call_payload(payload),
    do: %{
      text: Format.printable(payload, limit: @call_payload_chars),
      bytes: Format.payload_bytes(payload)
    }

  defp call_at(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp call_at(_absent), do: DateTime.utc_now()

  @call_sources %{
    "ui" => "UI",
    "cli" => "CLI",
    "sdk" => "SDK",
    "http" => "HTTP",
    "mcp" => "MCP",
    "plugin" => "plugin",
    "relay" => "relay",
    "internal" => "internal"
  }

  # A source the console does not know reads as sent.
  defp call_source(source), do: Map.get(@call_sources, source, to_string(source || "unknown"))

  defp call_verdict(%{outcome: nil}), do: {"waiting", "flz-badge"}
  defp call_verdict(%{outcome: %{kind: :answered}}), do: {"answered", verdict_tone(:ok)}
  defp call_verdict(%{outcome: %{kind: :timed_out}}), do: {"timed out", verdict_tone(:warning)}
  defp call_verdict(%{outcome: %{kind: :refused}}), do: {"refused", verdict_tone(:problem)}

  defp call_verdict(%{outcome: %{kind: :not_heard}}),
    do: {"outcome not heard", verdict_tone(:warning)}

  # Read when the screen opens and when the API section opens, never on the
  # tick: the answer changes only when a runner announces again. The dead
  # render has no dialog to call from, so it does not read it.
  defp load_api(socket) do
    if connected?(socket), do: read_api(socket), else: socket
  end

  defp read_api(socket) do
    %{ns: ns, relay_id: id, flezha_token: token} = socket.assigns

    case NodeManager.relay_api(ns, id, token) do
      {:ok, api} -> assign(socket, api: api, api_error: nil)
      {:error, reason} -> assign(socket, api: [], api_error: reason)
    end
  end

  # The retained records, read when the input log section opens, never on the
  # tick; payloads are never read.
  defp load_inbox(%{assigns: %{input_log: nil}} = socket), do: socket

  defp load_inbox(socket) do
    case NodeManager.inbox(socket.assigns.relay_id, socket.assigns.flezha_token) do
      {:ok, inbox} -> assign(socket, inbox: inbox, inbox_error: nil)
      {:error, reason} -> assign(socket, inbox: nil, inbox_error: reason)
    end
  end

  defp load_data(socket) do
    %{ns: ns, relay_id: relay_id, flezha_token: token} = socket.assigns

    socket = assign(socket, row: namespace_row(ns, relay_id, token))

    socket =
      case NodeManager.overwatch_facts(ns, relay_id, token) do
        {:ok, facts} ->
          socket |> assign(load_error: nil) |> assign_facts(facts)

        {:error, reason} ->
          socket |> assign(load_error: reason) |> assign_facts(NodeManager.overwatch_facts())
      end

    socket |> assign_idle_bindings() |> load_durability()
  end

  # Bindings the controller declares for this relay that its hook table does
  # not hold: a disabled plugin or a provider that did not start. Listed so
  # they can be seen and unbound, since no other screen shows them. Read only
  # while the Plugins section is open, since it is a namespace-wide read, and
  # never against a hook table that failed to load, which would mark every
  # binding idle.
  defp assign_idle_bindings(
         %{assigns: %{load_error: nil, sections: %{"plugins" => true}}} = socket
       ) do
    %{ns: ns, relay_id: relay_id, bindings: bindings, flezha_token: token} = socket.assigns
    running = MapSet.new(bindings, & &1.plugin_id)

    idle =
      ns
      |> NodeManager.relay_plugins(token)
      |> NodeManager.ok_or([])
      |> NodeManager.declared_bindings(relay_id)
      |> Enum.reject(&MapSet.member?(running, &1.plugin_id))

    assign(socket, idle_bindings: Enum.sort_by(idle, & &1.plugin_id))
  end

  defp assign_idle_bindings(socket), do: assign(socket, idle_bindings: [])

  # One row per plugin, running ones first: a plugin bound on several hooks is
  # one binding, and is unbound as one.
  defp binding_rows(bindings, idle) do
    running =
      for {plugin_id, hooks} <- Enum.group_by(bindings, & &1.plugin_id) do
        %{
          plugin_id: plugin_id,
          hooks: Enum.map(hooks, & &1.hook),
          providers: hooks |> Enum.map(& &1.provider) |> Enum.uniq(),
          positions: hooks |> Enum.map(& &1.position) |> Enum.reject(&is_nil/1),
          idle?: false
        }
      end

    idle =
      for row <- idle do
        %{
          plugin_id: row.plugin_id,
          hooks: row.hooks,
          providers: [row.provider],
          positions: [],
          idle?: true
        }
      end

    running ++ idle
  end

  # A relay that has finished is not in the registry at all, so "no row and
  # no overwatch" is the signal to read its completion record rather than to
  # report the relay missing. Read on open, never on a tick.
  defp load_completion(%{assigns: %{row: nil}} = socket) do
    case NodeManager.completion(socket.assigns.relay_id, socket.assigns.flezha_token) do
      {:ok, record} when is_map(record) -> assign(socket, completion: record, load_error: nil)
      _none -> assign(socket, completion: nil)
    end
  end

  defp load_completion(socket), do: assign(socket, completion: nil)

  # The task journal and input log exist only for a durable steps relay.
  # Reading them for a flow relay would answer empty, which renders as "there
  # is nothing here" rather than "this does not apply".
  defp load_durability(%{assigns: %{run: :steps, durable_steps: true}} = socket) do
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

  # Health, live node and partition identity are registry facts, not overwatch
  # ones — they come from the same namespace-wide read the listing makes, so
  # this screen agrees with the listing it was reached from.
  defp namespace_row(ns, relay_id, token) do
    ns
    |> NodeManager.relay_rows(token)
    |> NodeManager.ok_or([])
    |> Enum.find(&(to_string(&1.id) == to_string(relay_id)))
  end

  # Spread for the panels that read one field each, and kept whole for the
  # pipeline graph, so a tick fetches the overwatch state once rather than
  # twice.
  defp assign_facts(socket, facts) do
    socket |> assign(facts) |> assign(overwatch: facts)
  end

  defp parse_iteration(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  @doc """
  A tap's `field` per second, measured over the tap's own window.

  Deliberately not a controller figure: nothing counts bytes on the data plane,
  so this is what the listener actually delivered while it was attached.
  """
  def tap_rate(tap, field) do
    elapsed = max(System.monotonic_time(:millisecond) - tap.started_at, 1) / 1_000

    Float.round(Map.fetch!(tap, field) / elapsed, 1)
  end

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

  @doc "The entry channels the relay's API announces, across its factory entries."
  def api_channels(api), do: Enum.flat_map(api, &List.wrap(&1[:channels]))

  defp talk_change(talk, params, api) do
    channel =
      case params["channel_pick"] do
        nil -> talk.channel
        picked -> Enum.find(api_channels(api), talk.channel, &(&1.channel == picked))
      end

    fields = Map.merge(talk.fields, Map.drop(params, ["channel_pick", "action"]))

    # A channel picked anew starts from empty fields: another channel's values
    # would be sent under names this one does not declare.
    fields =
      if channel != talk.channel, do: %{fields | "value" => %{}, "json" => ""}, else: fields

    %{talk | channel: channel, fields: fields}
  end

  # What a submit asks for, as its kind and the controller call to wait on, or
  # what stops it: a message, or `{:fields, errors}` for the generated fields
  # that fail. A call that cannot be made is refused here, before anything is
  # sent.
  defp talk_request(%{mode: :channel, channel: nil}, _action, _relay),
    do: {:error, "The relay's API announces no channel to call."}

  defp talk_request(%{mode: :channel, channel: channel, fields: fields}, _action, relay) do
    {ns, id, token} = relay

    with {:ok, value} <- channel_value(channel, fields),
         {:ok, deadline_ms} <- deadline(fields["deadline_ms"]) do
      opts = [deadline_ms: deadline_ms]

      {:ok, :channel,
       fn -> NodeManager.call_channel(ns, id, channel.channel, value, opts, token) end}
    end
  end

  defp talk_request(%{mode: :raw, fields: fields}, "call", {ns, id, token}) do
    with {:ok, deadline_ms} <- deadline(fields["deadline_ms"]) do
      opts = put_text([deadline_ms: deadline_ms], :key, fields["key"])
      payload = fields["payload"] || ""
      channel = trimmed(fields["channel"])
      {:ok, :call, fn -> NodeManager.call_relay(ns, id, payload, channel, opts, token) end}
    end
  end

  defp talk_request(%{mode: :raw, fields: fields}, _send, {ns, id, token}) do
    opts = [] |> put_text(:key, fields["key"]) |> put_text(:msg_id, fields["msg_id"])
    payload = fields["payload"] || ""
    channel = trimmed(fields["channel"])
    {:ok, :send, fn -> NodeManager.send_relay(ns, id, payload, channel, opts, token) end}
  end

  # A call holds an async task and a controller call for its whole deadline,
  # so it is bounded here; five minutes outlasts any answer worth waiting for.
  @max_deadline_ms 300_000

  defp deadline(raw) do
    case Integer.parse(trimmed(raw)) do
      {ms, ""} when ms > 0 and ms <= @max_deadline_ms ->
        {:ok, ms}

      _invalid ->
        {:error,
         "The deadline must be a whole number of milliseconds from 1 to #{@max_deadline_ms}."}
    end
  end

  defp put_text(opts, key, value) do
    case trimmed(value) do
      "" -> opts
      text -> Keyword.put(opts, key, text)
    end
  end

  defp trimmed(value), do: String.trim(value || "")

  @doc """
  How a channel's value is entered: `{:fields, specs}` generated from a flat
  object schema as `FlezhaUiWeb.Live.TypedFields` specs, `:json` for any other
  JSON value, or `:text` for a channel whose format is not JSON (text as typed,
  base64 for the binary formats).
  """
  def channel_form(%{codec: "json", schema: schema}), do: schema_fields(schema)
  def channel_form(_channel), do: :text

  # A top-level object whose every property is a string, enum, number, integer
  # or boolean becomes one field per property; anything else is one JSON value.
  defp schema_fields(%{"type" => "object", "properties" => properties} = schema)
       when is_map(properties) and map_size(properties) > 0 do
    required = List.wrap(schema["required"])

    fields =
      for {name, property} <- Enum.sort(properties),
          do: schema_field(name, property, name in required)

    if Enum.all?(fields) and TypedFields.fits?(fields), do: {:fields, fields}, else: :json
  end

  defp schema_fields(_schema), do: :json

  # An enum is chosen by its text and sent as the value the schema lists, so a
  # numeric or boolean enum keeps its type.
  defp schema_field(name, %{"enum" => values}, required) when is_list(values),
    do: %{name: name, kind: :enum, values: values, required: required}

  defp schema_field(name, %{"type" => type}, required)
       when type in ~w(string number integer boolean),
       do: %{name: name, kind: schema_kind(type), required: required}

  defp schema_field(_name, _property, _required), do: nil

  defp schema_kind("string"), do: :string
  defp schema_kind("number"), do: :number
  defp schema_kind("integer"), do: :int
  defp schema_kind("boolean"), do: :bool

  defp channel_value(channel, fields) do
    case channel_form(channel) do
      {:fields, specs} ->
        specs
        |> TypedFields.changeset(fields["value"] || %{}, required?: true)
        |> TypedFields.values()
        |> case do
          {:ok, value} -> {:ok, value}
          {:error, errors} -> {:error, {:fields, errors}}
        end

      :json ->
        json_value(fields["json"])

      :text ->
        {:ok, fields["json"] || ""}
    end
  end

  defp json_value(raw) do
    case Jason.decode(trimmed(raw)) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, "The value must be valid JSON."}
    end
  end

  @doc "An answer as text: JSON for a decoded value, the payload as it came otherwise."
  def answer_text(value) when is_binary(value), do: Format.printable(value)
  def answer_text(value), do: Jason.encode!(value, pretty: true)

  defp verdict_tone(:ok), do: "flz-badge flz-badge--positive"
  defp verdict_tone(:warning), do: "flz-badge flz-badge--warning"
  defp verdict_tone(_problem), do: "flz-badge flz-badge--negative"

  # The controller answers `-1` for an input log that holds no records.
  defp last_offset(-1), do: "no records"
  defp last_offset(nil), do: "—"
  defp last_offset(offset), do: offset

  defp format_input_type("1"), do: "Binary (1)"
  defp format_input_type("2"), do: "Text (2)"
  defp format_input_type("3"), do: "Custom (3)"
  defp format_input_type(other) when is_binary(other), do: "Unknown (#{other})"
  defp format_input_type(_), do: "—"
end
