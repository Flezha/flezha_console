defmodule FlezhaUiWeb.RelayLive do
  @moduledoc """
  A relay's Live view: what it is doing. Its sentence header, its pipeline
  graph and payload tap, and on request its diagnosis, the calls made to it,
  its API and its plugin bindings. What it has kept — its cells, task journal,
  input log and steps facts — is on its State view.
  """

  use FlezhaUiWeb, :live_view

  # The pipeline graph reads its rates from snapshot deltas, so this screen
  # ticks at the rate those deltas are worth measuring over. A runner flip is
  # the one state change worth showing before the next tick.
  use FlezhaUiWeb.Live.Refresh,
    every: 2_000,
    on_events: [:runner_connected, :runner_disconnected]

  use FlezhaUiWeb.Topology
  use FlezhaUiWeb.Live.PluginForm

  # The graph and the relay's own facts are what the screen is for; the
  # diagnosis, the calls, the API and the bindings are what an operator goes
  # looking for, so they start folded away.
  use FlezhaUiWeb.Live.Sections,
    open: %{
      "diagnosis" => false,
      "api" => false,
      "calls" => false,
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
        load_error: nil,
        confirm_stop: false,
        confirm_unbind: nil,
        idle_bindings: [],
        completion: nil,
        tap: nil,
        diagnosis: nil,
        diagnosis_error: nil,
        api: [],
        api_error: nil,
        calls: nil,
        talk: nil,
        talk_results: []
      )
      |> assign_feeding()
      |> load_data()
      |> load_completion()
      |> load_api()
      |> Topology.load_pipeline()

    {:ok, socket}
  end

  # Which providers feed a relay decides which plugins are drawn as sources.
  # The listing changes only when the controller installs a provider, so it is
  # read once per visit.
  defp assign_feeding(socket) do
    feeding =
      if connected?(socket), do: NodeManager.feeding_providers(socket.assigns.flezha_token)

    assign(socket, feeding: feeding)
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    socket
    |> load_data()
    |> Topology.load_pipeline()
  end

  # A hidden page reads nothing, so it holds no tally either; the next
  # visible tick opens one again.
  @impl FlezhaUiWeb.Live.Refresh
  def refresh_hidden(socket), do: Topology.stop_tally(socket)

  # `?do=` lands an action from the command palette on the screen that owns
  # it: a stop opens this screen's own confirmation, and a diagnosis is asked
  # for once and shown open.
  @impl true
  def handle_params(%{"do" => "stop"}, _uri, socket) do
    if is_nil(socket.assigns.completion) and
         NodeManager.granted?(socket.assigns.operations, "Relay.stop"),
       do: {:noreply, socket |> assign(confirm_stop: true) |> done_with_action()},
       else: {:noreply, done_with_action(socket)}
  end

  def handle_params(%{"do" => "diagnose"}, _uri, socket) do
    if connected?(socket) and NodeManager.granted?(socket.assigns.operations, "Relay.diagnose"),
      do: {:noreply, socket |> diagnose() |> done_with_action()},
      else: {:noreply, done_with_action(socket)}
  end

  def handle_params(%{"do" => "talk"}, _uri, socket) do
    if is_nil(socket.assigns.completion) and
         NodeManager.granted?(socket.assigns.operations, "Relay.send"),
       do: {:noreply, socket |> open_talk() |> done_with_action()},
       else: {:noreply, done_with_action(socket)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # Once applied, the action leaves the address, so a reload or a reconnect
  # does not open it again. The dead render has no client to patch.
  defp done_with_action(socket) do
    if connected?(socket),
      do:
        push_patch(socket,
          to: ~p"/namespaces/#{socket.assigns.ns}/relays/#{socket.assigns.relay_id}"
        ),
      else: socket
  end

  # ---- Payload tap ----
  #
  # A listen on the relay's input or output, opened from one of its channel
  # ports and held by a feed linked to this screen: closing the tap or leaving
  # the page stops the feed, which ends the listen on the controller. An
  # output tap shows its own channel's records until asked for every channel.
  # What it hears is also pushed to the graph, which draws each record on the
  # tapped port's wires: coalesced under one timer, so a busy relay sends one
  # push per flush rather than one per record.

  @default_tap_flush_ms 250
  @tap_previews 6
  @tap_preview_chars 40

  @impl true
  def handle_event(
        "graph_tap",
        %{"port" => "entry-" <> _ = port, "direction" => "input"},
        socket
      ),
      do: open_tap(socket, port, "input")

  def handle_event(
        "graph_tap",
        %{"port" => "exit-" <> _ = port, "direction" => "output"},
        socket
      ),
      do: open_tap(socket, port, "output")

  # A port the graph does not draw, or one tapped the wrong way, opens nothing.
  def handle_event("graph_tap", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("graph_tap_close", _params, socket) do
    {:noreply, close_tap(socket)}
  end

  @impl true
  def handle_event("graph_tap_all", _params, %{assigns: %{tap: %{} = tap}} = socket) do
    {:noreply, assign(socket, tap: %{tap | all?: true})}
  end

  def handle_event("graph_tap_all", _params, socket), do: {:noreply, socket}

  # Only an open panel listens, whatever the client sends.
  @impl true
  def handle_event("calls_reopen", _params, socket) do
    if socket.assigns.sections["calls"],
      do: {:noreply, open_calls(socket)},
      else: {:noreply, socket}
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
  def handle_event("diagnose", _params, socket), do: {:noreply, diagnose(socket)}

  # ---- Talking to the relay ----
  #
  # One dialog sends to the relay, calls it, or calls an entry channel its API
  # announces. A call waits for the relay's answer, so it runs as an async
  # task: the screen keeps refreshing, and closing the dialog cancels the wait.

  @impl true
  def handle_event("talk_open", _params, socket), do: {:noreply, open_talk(socket)}

  @impl true
  def handle_event("talk_close", _params, socket) do
    {:noreply, socket |> cancel_async(:talk) |> assign(talk: nil)}
  end

  def handle_event(event, _params, %{assigns: %{talk: nil}} = socket)
      when event in ~w(talk_mode talk_change talk_submit),
      do: {:noreply, socket}

  @impl true
  def handle_event("talk_mode", %{"value" => mode}, socket) when mode in ~w(channel raw) do
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

  defp open_talk(socket) do
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

    assign(socket, talk: talk)
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
  def section_opened(socket, "calls"), do: open_calls(socket)
  def section_opened(socket, "plugins"), do: assign_idle_bindings(socket)
  def section_opened(socket, _key), do: socket

  def section_closed(socket, "calls"), do: close_calls(socket)
  def section_closed(socket, _key), do: socket

  @impl true
  def handle_info({kind, :payload_tap, event}, %{assigns: %{tap: %{} = tap}} = socket) do
    {:noreply, assign(socket, tap: tap |> tap_event(kind, event) |> arm_flush())}
  end

  # A flush armed for a tap since closed or replaced is not this tap's.
  @impl true
  def handle_info({:tap_flush, ref}, %{assigns: %{tap: %{flush: {ref, _timer}} = tap}} = socket) do
    %{records: records, previews: previews} = tap.pending

    {:noreply,
     socket
     |> assign(tap: %{tap | pending: no_pending(), flush: nil})
     |> push_event("pipeline_records", %{
       port: tap.port,
       records: records,
       previews: Enum.reverse(previews)
     })}
  end

  @impl true
  def handle_info({kind, :pipeline_tally, event}, socket) do
    {:noreply, Topology.tally(socket, kind, event)}
  end

  @impl true
  def handle_info({kind, :call_activity, event}, %{assigns: %{calls: %{} = calls}} = socket) do
    {:noreply, assign(socket, calls: call_event(calls, kind, event))}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # Another channel's record, on an output tap showing its own channel.
  defp tap_event(
         %{channel: channel, all?: false} = tap,
         :feed_event,
         {kind, _payload, %{"channel" => other}}
       )
       when kind in [:output, :part] and is_binary(channel) and other != channel,
       do: tap

  defp tap_event(tap, :feed_event, {kind, payload, meta}) when kind in [:output, :input, :part] do
    frame = Format.frame(payload, meta)
    pending = tap.pending

    previews =
      if length(pending.previews) < @tap_previews,
        do: [Format.printable(payload, limit: @tap_preview_chars) | pending.previews],
        else: pending.previews

    %{
      tap
      | count: tap.count + 1,
        bytes: tap.bytes + frame.bytes,
        recent: Enum.take([frame | tap.recent], 5),
        pending: %{pending | records: pending.records + 1, previews: previews}
    }
  end

  defp tap_event(tap, :feed_event, {:dead_lettered, _error, _meta}) do
    %{tap | dead_letters: tap.dead_letters + 1}
  end

  # Either way the feed has stopped, so the tap is no longer live.
  defp tap_event(tap, :feed_error, reason), do: %{tap | error: reason, feed: nil}
  defp tap_event(tap, :feed_ended, _answer), do: %{tap | ended?: true, feed: nil}
  defp tap_event(tap, _kind, _event), do: tap

  defp open_tap(socket, port, direction) do
    socket = close_tap(socket)

    socket =
      assign(socket,
        tap: %{
          direction: direction,
          port: port,
          channel: if(direction == "output", do: String.replace_prefix(port, "exit-", "")),
          all?: false,
          feed: listen_feed(socket, String.to_existing_atom(direction), :payload_tap),
          started_at: System.monotonic_time(:millisecond),
          count: 0,
          bytes: 0,
          recent: [],
          dead_letters: 0,
          pending: no_pending(),
          flush: nil,
          error: nil,
          ended?: false
        }
      )

    {:noreply, Topology.handle_event("graph_select", %{"id" => port}, socket)}
  end

  defp close_tap(%{assigns: %{tap: nil}} = socket), do: socket

  defp close_tap(%{assigns: %{tap: tap}} = socket) do
    EventFeed.stop(tap.feed, :payload_tap)
    with {_ref, timer} <- tap.flush, do: Process.cancel_timer(timer)
    assign(socket, tap: nil)
  end

  defp no_pending, do: %{records: 0, previews: []}

  defp arm_flush(%{flush: nil, pending: %{records: 0}} = tap), do: tap

  defp arm_flush(%{flush: nil} = tap) do
    ref = make_ref()
    %{tap | flush: {ref, Process.send_after(self(), {:tap_flush, ref}, tap_flush_ms())}}
  end

  defp arm_flush(tap), do: tap

  defp tap_flush_ms, do: Application.get_env(:flezha_ui, :tap_flush_ms, @default_tap_flush_ms)

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

  # A source the console does not know reads as sent.
  defp call_source(source), do: Words.text(:call_source, source || "unknown")

  defp call_outcome_kind(%{outcome: nil}), do: nil
  defp call_outcome_kind(%{outcome: %{kind: kind}}), do: kind

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

  defp load_data(socket) do
    %{ns: ns, relay_id: relay_id, flezha_token: token} = socket.assigns

    # Health, live node and partition identity are registry facts, not
    # overwatch ones — they come from the same namespace-wide read the listing
    # makes, so this screen agrees with the listing it was reached from.
    rows = ns |> NodeManager.relay_rows(token) |> NodeManager.ok_or([])

    socket =
      assign(socket,
        row: NodeManager.relay_row(rows, relay_id),
        partitions: NodeManager.partition_members(rows, relay_id)
      )

    socket =
      case NodeManager.overwatch_facts(ns, relay_id, token, socket.assigns[:feeding]) do
        {:ok, facts} ->
          socket |> assign(load_error: nil) |> assign_facts(facts)

        {:error, reason} ->
          socket |> assign(load_error: reason) |> assign_facts(NodeManager.overwatch_facts())
      end

    assign_idle_bindings(socket)
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

  # Spread for the panels that read one field each, and kept whole for the
  # pipeline graph, so a tick fetches the overwatch state once rather than
  # twice.
  defp assign_facts(socket, facts) do
    socket |> assign(facts) |> assign(overwatch: facts)
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

  # On request only: the controller reads verdicts, runners, dead letters and
  # the input log to answer it, so it never rides the tick. The answer opens
  # its section.
  defp diagnose(socket) do
    %{ns: ns, relay_id: id, flezha_token: token} = socket.assigns

    socket =
      case NodeManager.diagnose_relay(ns, id, token) do
        {:ok, diagnosis} -> assign(socket, diagnosis: diagnosis, diagnosis_error: nil)
        {:error, reason} -> assign(socket, diagnosis: nil, diagnosis_error: reason)
      end

    assign(socket, sections: Map.put(socket.assigns.sections, "diagnosis", true))
  end

  @doc """
  The relay's header sentence: what it is, where it runs and its condition,
  as `[{fragment, testid}]` so each fact stays addressable.
  """
  def sentence_parts(assigns) do
    %{run: run, factory_id: factory, runner_id: runner, uptime_ms: uptime, row: row} = assigns

    [
      {if(run, do: "A #{run} relay", else: "A relay"), "relay-run"},
      {factory && " from #{factory}", "relay-factory"},
      {{:runner, runner != nil}, nil},
      {runner && " #{short(runner)}", "relay-runner"},
      {(row && row[:node] && " on #{row.node}") || (row && " — unplaced"), "relay-node"},
      {uptime && ", up for #{Format.duration(uptime)}", "relay-uptime"}
    ]
    |> Enum.reject(fn {text, _testid} -> is_nil(text) or text == false end)
  end

  defp short(id) do
    id = to_string(id)
    if String.length(id) > 16, do: "…" <> String.slice(id, -7, 7), else: id
  end

  @doc "A folded section's digest for the calls it has heard."
  def calls_digest(nil), do: "not listening"
  def calls_digest(%{entries: []}), do: "none heard yet"
  def calls_digest(%{entries: entries}), do: Words.count(length(entries), "call") <> " heard"
end
