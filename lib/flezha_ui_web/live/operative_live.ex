defmodule FlezhaUiWeb.OperativeLive do
  use FlezhaUiWeb, :live_view

  # The pipeline graph reads its rates from snapshot deltas, so this screen
  # ticks whether or not the operator armed the entity-state panel. A runner
  # flip is the one state change worth showing before the next tick.
  use FlezhaUiWeb.Live.Refresh,
    every: 2_000,
    on_events: [:runner_connected, :runner_disconnected]

  use FlezhaUiWeb.Topology

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUi.Service.StreamBridge
  alias FlezhaUiWeb.Topology

  @impl true
  def mount(%{"ns" => ns, "id" => id}, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> Topology.init()
      |> assign(
        ns: ns,
        operative_id: id,
        page_title: id,
        state_json: nil,
        state_seq: nil,
        state_notice: nil,
        load_error: nil,
        selector_form: %{"procedure" => "", "entity_key" => ""},
        auto_refresh_state: false,
        confirm_stop: false,
        show_attach_modal: false,
        attach_step: :choose_provider,
        attach_provider_id: nil,
        attach_form: %{},
        attach_error: nil,
        confirm_detach: nil,
        tap: nil,
        enabled_providers: Enum.reject(NodeManager.providers(), & &1.internal?)
      )
      |> load_data()
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

  # The entity-state panel reloads only when the operator armed it; the graph
  # ticks regardless, because a rate needs two snapshots to exist at all.
  defp maybe_fetch_state(socket) do
    if socket.assigns.auto_refresh_state, do: fetch_state(socket), else: socket
  end

  # ---- Payload tap ----
  #
  # `StreamBridge` attaches the controller's monitored-I/O listener on demand,
  # reference-counts viewers and detaches when the last one goes — including a
  # LiveView that died without saying goodbye. The tap is that bridge with a
  # meter on it.

  @impl true
  def handle_event("graph_tap", %{"io" => io_type}, socket) when io_type in ~w(input output) do
    %{ns: ns, operative_id: id} = socket.assigns
    socket = close_tap(socket)
    StreamBridge.subscribe(ns, id, io_type)

    {:noreply,
     assign(socket,
       tap: %{
         io_type: io_type,
         started_at: System.monotonic_time(:millisecond),
         count: 0,
         bytes: 0,
         recent: [],
         error: nil
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
  def handle_event("confirm_stop", _params, socket) do
    {:noreply, assign(socket, confirm_stop: true)}
  end

  @impl true
  def handle_event("cancel_stop", _params, socket) do
    {:noreply, assign(socket, confirm_stop: false)}
  end

  @impl true
  def handle_event("stop_operative", _params, socket) do
    %{ns: ns, operative_id: id} = socket.assigns

    case NodeManager.stop_operative(ns, id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Operative stopped.")
         |> push_navigate(to: ~p"/namespaces/#{ns}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_stop: false)
         |> put_flash(:error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("open_attach_modal", _params, socket) do
    {:noreply,
     assign(socket,
       show_attach_modal: true,
       attach_step: :choose_provider,
       attach_provider_id: nil,
       attach_form: %{
         "plugin_id" => generate_plugin_id(),
         "trigger" => "on_output",
         # Left blank, not defaulted: position only applies to ordered
         # extensions, and sending it for any other kind is refused outright.
         "position" => ""
       },
       attach_error: nil
     )}
  end

  @impl true
  def handle_event("close_attach_modal", _params, socket) do
    {:noreply, assign(socket, show_attach_modal: false)}
  end

  @impl true
  def handle_event("choose_provider", %{"provider_id" => pid}, socket) do
    {:noreply, assign(socket, attach_provider_id: pid, attach_step: :configure)}
  end

  @impl true
  def handle_event("attach_form_change", %{"plugin" => params}, socket) do
    {:noreply, assign(socket, attach_form: Map.merge(socket.assigns.attach_form, params))}
  end

  @impl true
  def handle_event("attach_plugin", %{"plugin" => params}, socket) do
    %{ns: ns, operative_id: operative_id, attach_provider_id: provider_id} = socket.assigns
    form = Map.merge(socket.assigns.attach_form, params)
    plugin_id = form["plugin_id"]

    provider = find_provider(socket.assigns.enabled_providers, provider_id)

    plugin_form =
      provider
      |> extract_provider_settings(form)
      |> Map.put("trigger", form["trigger"])
      |> Map.put("sub_position", form["position"] || "")

    case NodeManager.enable_plugin(plugin_id, provider, plugin_form, ns, operative_id) do
      {:ok, _} ->
        socket =
          socket
          |> assign(show_attach_modal: false, attach_error: nil)
          |> load_data()
          |> put_flash(:info, "Plugin attached.")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, attach_error: plugin_error(reason))}
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
    case NodeManager.disable_plugin(plugin_id) do
      success when success == :ok or (is_tuple(success) and elem(success, 0) == :ok) ->
        socket =
          socket
          |> assign(confirm_detach: nil)
          |> load_data()
          |> put_flash(:info, "Plugin detached.")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_detach: nil)
         |> put_flash(:error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:stream_message, msg}, %{assigns: %{tap: tap}} = socket) when is_map(tap) do
    tap = %{
      tap
      | count: tap.count + 1,
        bytes: tap.bytes + Map.get(msg, :bytes, 0),
        recent: Enum.take([msg | tap.recent], 5)
    }

    {:noreply, assign(socket, tap: tap)}
  end

  @impl true
  def handle_info({:stream_status, {:error, reason}}, %{assigns: %{tap: tap}} = socket)
      when is_map(tap) do
    {:noreply, assign(socket, tap: %{tap | error: reason})}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp close_tap(%{assigns: %{tap: nil}} = socket), do: socket

  defp close_tap(%{assigns: %{tap: tap}} = socket) do
    StreamBridge.unsubscribe(socket.assigns.ns, socket.assigns.operative_id, tap.io_type)
    assign(socket, tap: nil)
  end

  defp load_data(socket) do
    %{ns: ns, operative_id: operative_id} = socket.assigns

    case NodeManager.overwatch_facts(ns, operative_id) do
      {:ok, facts} -> socket |> assign(load_error: nil) |> assign_facts(facts)
      {:error, reason} -> socket |> assign(load_error: reason) |> assign_facts(overwatch_facts())
    end
  end

  # Spread for the panels that read one field each, and kept whole for the
  # pipeline graph, so a tick fetches the overwatch state once rather than
  # twice.
  defp assign_facts(socket, facts) do
    socket |> assign(facts) |> assign(overwatch: facts)
  end

  defp overwatch_facts, do: NodeManager.overwatch_facts()

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
    %{ns: ns, operative_id: id, selector_form: form} = socket.assigns

    case NodeManager.entity_state(ns, id, selector(form)) do
      {:ok, json, change_seq} ->
        assign(socket, state_json: json, state_seq: change_seq, state_notice: nil)

      {:error, reason} ->
        assign(socket, state_json: nil, state_seq: nil, state_notice: state_notice(reason))
    end
  end

  # `%{}` reads every Procedure; a procedure alone narrows to that Procedure;
  # both narrow to the single Entity.
  defp selector(form) do
    procedure = String.trim(form["procedure"] || "")
    entity_key = String.trim(form["entity_key"] || "")

    cond do
      procedure == "" -> %{}
      entity_key == "" -> %{procedure: procedure}
      true -> %{procedure: procedure, entity_key: entity_key}
    end
  end

  # These are explanations, not failures: the operative is healthy, the state
  # just is not there to read.
  defp state_notice({:unsupported_for_kind, :persistent_state}) do
    {:info,
     "This operative's kind has no per-entity state. Only kinds declaring " <>
       "persistent state (e.g. :stream) can be introspected this way."}
  end

  defp state_notice({:not_resident, reason}) do
    {:info, "This entity is not held in memory: #{inspect(reason)}."}
  end

  defp state_notice(:not_found) do
    {:info, "No state found for this selector."}
  end

  defp state_notice(reason), do: {:error, reason}

  defp find_provider(providers, provider_id) do
    Enum.find(providers, fn p -> p.id == provider_id end)
  end

  defp extract_provider_settings(nil, _form), do: %{}

  defp extract_provider_settings(provider, form) do
    all_fields = provider.required_fields ++ provider.optional_fields

    Enum.reduce(all_fields, %{}, fn field, acc ->
      raw = Map.get(form, "field_#{field}", "")
      if raw == "", do: acc, else: Map.put(acc, field, raw)
    end)
  end

  defp generate_plugin_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # TODO: add more types here if the agent adds new input types (e.g. "3" = custom)
  defp format_input_type("1"), do: "Binary (1)"
  defp format_input_type("2"), do: "Text (2)"
  defp format_input_type("3"), do: "Custom (3)"
  defp format_input_type(other) when is_binary(other), do: "Unknown (#{other})"
  defp format_input_type(_), do: "—"

  # The extension table's refusals, in the operator's terms. Each names what to
  # change rather than restating the atom.
  defp plugin_error(:position_not_applicable) do
    "Position applies only to ordered extensions (on_input, on_output). Leave it blank for this one."
  end

  defp plugin_error({:invalid_subscription_opts, {:interval_ms, _}}) do
    "on_interval needs an interval in milliseconds."
  end

  defp plugin_error({:invalid_subscription_opts, {key, value}}) do
    "The controller rejected #{key}: #{inspect(value)}"
  end

  defp plugin_error({:unknown_extension, name}) do
    "#{name} is not an extension point on this host."
  end

  defp plugin_error({:extension_not_exported, extension}) do
    "This provider does not implement #{extension}, so it cannot subscribe to it."
  end

  defp plugin_error(reason) when is_binary(reason), do: reason
  defp plugin_error(reason), do: "The controller refused the plugin: #{inspect(reason)}"

  # The host's extension points, plus the controller's legacy trigger spellings
  # for an interval subscription.
  defp trigger_options do
    Enum.map(NodeManager.extensions(), &Atom.to_string/1) ++ ~w(proactive interval)
  end
end
