defmodule FlezhaUiWeb.RelayLive do
  use FlezhaUiWeb, :live_view

  # The pipeline graph reads its rates from snapshot deltas, so this screen
  # ticks whether or not the operator armed the cell-state panel. A runner
  # flip is the one state change worth showing before the next tick.
  use FlezhaUiWeb.Live.Refresh,
    every: 2_000,
    on_events: [:runner_connected, :runner_disconnected]

  use FlezhaUiWeb.Topology

  # The graph and the relay's own facts are what the screen is for; the task
  # journal, the input log, the SDK state and the bindings are what an
  # operator goes looking for, so they start folded away.
  use FlezhaUiWeb.Live.Sections,
    open: %{"journal" => false, "input-log" => false, "sdk-state" => false, "plugins" => false}

  alias FlezhaUi.Format
  alias FlezhaUi.Service.EventFeed
  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Topology

  @impl true
  def mount(%{"ns" => ns, "id" => id}, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> Topology.init()
      |> sections_init()
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
        attach: nil,
        confirm_detach: nil,
        rewind_target: nil,
        completion: nil,
        journal: nil,
        committed_iterations: [],
        input_log: nil,
        tap: nil
      )
      |> load_data()
      |> load_completion()
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
    %{ns: ns, relay_id: id, flezha_token: token} = socket.assigns

    {:ok, feed} =
      EventFeed.start_link(
        open: &NodeManager.listen(ns, id, String.to_existing_atom(direction), token, &1),
        to: {:send, self(), :payload_tap}
      )

    {:noreply,
     assign(socket,
       tap: %{
         direction: direction,
         feed: feed,
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
  def handle_event("open_attach", _params, socket) do
    {providers, error} =
      socket.assigns.flezha_token |> NodeManager.providers() |> NodeManager.ok_or_error([])

    {:noreply,
     assign(socket,
       attach: %{
         providers: providers,
         providers_error: error,
         provider: nil,
         form: %{"name" => generate_plugin_name(), "opts" => "", "hooks" => []},
         error: nil
       }
     )}
  end

  @impl true
  def handle_event("close_attach", _params, socket) do
    {:noreply, assign(socket, attach: nil)}
  end

  # A form event that lands after its dialog closed has nothing to act on.
  def handle_event(event, _params, %{assigns: %{attach: nil}} = socket)
      when event in ~w(choose_provider attach_change attach_plugin),
      do: {:noreply, socket}

  # The provider's own description — its help and the hooks it supports — is
  # read once on selection rather than on every keystroke. A provider whose
  # help cannot be read still renders the form, without the help.
  @impl true
  def handle_event("choose_provider", %{"provider" => id}, socket) do
    provider =
      case NodeManager.provider(id, socket.assigns.flezha_token) do
        {:ok, described} -> Map.put(described, :id, id)
        {:error, _reason} -> %{id: id, help: nil, hooks: []}
      end

    {:noreply, update(socket, :attach, &%{&1 | provider: provider, error: nil})}
  end

  @impl true
  def handle_event("attach_change", %{"plugin" => params}, socket) do
    {:noreply,
     update(socket, :attach, fn attach ->
       %{attach | form: Map.merge(attach.form, Map.put_new(params, "hooks", []))}
     end)}
  end

  @impl true
  def handle_event("attach_plugin", %{"plugin" => params}, socket) do
    %{ns: ns, relay_id: relay_id, attach: attach, flezha_token: token} = socket.assigns
    form = Map.merge(attach.form, Map.put_new(params, "hooks", []))
    name = String.trim(form["name"] || "")

    with :ok <- require_name(name),
         {:ok, opts} <- parse_opts(form["opts"]) do
      fields = %{
        provider: attach.provider.id,
        opts: opts,
        namespace: ns,
        relay_id: relay_id,
        hooks: Enum.reject(List.wrap(form["hooks"]), &(&1 == ""))
      }

      case NodeManager.enable_plugin(name, fields, token) do
        {:ok, answer} ->
          {:noreply,
           socket
           |> assign(attach: nil)
           |> load_data()
           |> put_flash(:info, attached_message(name, answer))}

        {:error, reason} ->
          {:noreply, assign(socket, attach: %{attach | form: form, error: reason})}
      end
    else
      {:error, message} ->
        {:noreply, assign(socket, attach: %{attach | form: form, error: message})}
    end
  end

  @impl true
  def handle_event("confirm_detach", %{"plugin_id" => plugin_id}, socket) do
    {:noreply, assign(socket, confirm_detach: plugin_id)}
  end

  @impl true
  def handle_event("cancel_detach", _params, socket) do
    {:noreply, assign(socket, confirm_detach: nil)}
  end

  @impl true
  def handle_event("detach_plugin", %{"plugin_id" => plugin_id}, socket) do
    case NodeManager.disable_plugin(plugin_id, socket.assigns.ns, socket.assigns.flezha_token) do
      :ok ->
        {:noreply,
         socket
         |> assign(confirm_detach: nil)
         |> load_data()
         |> put_flash(:info, "Plugin #{plugin_id} disabled.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_detach: nil)
         |> put_flash(:error, error_message(reason, "the disable"))}
    end
  end

  @impl true
  def handle_info({kind, :payload_tap, event}, %{assigns: %{tap: %{} = tap}} = socket) do
    {:noreply, assign(socket, tap: tap_event(tap, kind, event))}
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

    load_durability(socket)
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

  defp attached_message(name, %{outcome: :already_enabled}),
    do: "Plugin #{name} was already enabled; this relay is bound to it."

  defp attached_message(name, _answer), do: "Plugin #{name} enabled and bound to this relay."

  defp require_name(""), do: {:error, "A plugin name is required."}
  defp require_name(_name), do: :ok

  # The provider describes its options only in its help text, so they are
  # taken as one JSON object, keyed by text: the controller turns only names
  # the provider declares into atoms.
  defp parse_opts(raw) do
    case String.trim(raw || "") do
      "" ->
        {:ok, %{}}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = opts} -> {:ok, opts}
          _not_an_object -> {:error, "Options must be a JSON object."}
        end
    end
  end

  defp generate_plugin_name do
    "plugin-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end

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
