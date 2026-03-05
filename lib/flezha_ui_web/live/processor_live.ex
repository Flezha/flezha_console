defmodule FlezhaUiWeb.ProcessorLive do
  use FlezhaUiWeb, :live_view

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUi.PluginSchema

  @impl true
  def mount(%{"ns" => ns, "id" => id}, _session, socket) do
    socket =
      socket
      |> assign(
        ns: ns,
        proc_id: id,
        page_title: id,
        state_json: nil,
        auto_refresh_state: false,
        confirm_stop: false,
        show_attach_modal: false,
        attach_step: :choose_provider,
        attach_provider_id: nil,
        attach_form: %{},
        attach_error: nil,
        confirm_detach: nil,
        enabled_providers: load_enabled_providers()
      )
      |> load_data()

    if connected?(socket), do: schedule_refresh()
    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    if socket.assigns.auto_refresh_state do
      schedule_refresh()
      {:noreply, fetch_state(socket)}
    else
      {:noreply, socket}
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, 2_000)
  end

  @impl true
  def handle_event("fetch_state", _params, socket) do
    {:noreply, fetch_state(socket)}
  end

  @impl true
  def handle_event("toggle_auto_refresh", _params, socket) do
    new_val = !socket.assigns.auto_refresh_state
    if new_val, do: schedule_refresh()
    {:noreply, assign(socket, auto_refresh_state: new_val)}
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
  def handle_event("stop_processor", _params, socket) do
    %{ns: ns, proc_id: id} = socket.assigns

    case NodeManager.stop_processor(ns, id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Processor stopped.")
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
         "position" => "0"
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
    %{ns: ns, proc_id: proc_id, attach_provider_id: provider_id} = socket.assigns
    form = Map.merge(socket.assigns.attach_form, params)
    plugin_id = form["plugin_id"]
    trigger = form["trigger"]
    position = String.to_integer(form["position"] || "0")

    provider_schema = PluginSchema.provider(provider_id)
    settings = extract_provider_settings(provider_schema, form)

    plugin_map = %{
      namespace: ns,
      processor_id: proc_id,
      trigger: trigger,
      position: position,
      provider_id: provider_id,
      provider_settings: settings
    }

    case NodeManager.enable_plugin(plugin_id, plugin_map) do
      {:ok, _} ->
        socket =
          socket
          |> assign(show_attach_modal: false, attach_error: nil)
          |> load_data()
          |> put_flash(:info, "Plugin attached.")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, attach_error: inspect(reason))}
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
      {:ok, _} ->
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

  defp load_data(socket) do
    %{ns: ns, proc_id: proc_id} = socket.assigns

    {factory_id, compute_engine_id, bindings, default_input_type} =
      case NodeManager.get_overwatch_state(ns, proc_id) do
        {:ok, state} ->
          {
            Map.get(state, :factory_id) || Map.get(state, "factory_id"),
            Map.get(state, :compute_engine_id) || Map.get(state, "compute_engine_id"),
            Map.get(state, :bindings) || Map.get(state, "bindings") || %{},
            Map.get(state, :default_input_type) || Map.get(state, "default_input_type")
          }

        _ ->
          {nil, nil, %{}, nil}
      end

    assign(socket,
      factory_id: factory_id,
      compute_engine_id: compute_engine_id,
      bindings: bindings,
      default_input_type: default_input_type
    )
  end

  defp fetch_state(socket) do
    %{ns: ns, proc_id: id} = socket.assigns

    state =
      case NodeManager.processor_state(ns, id) do
        {:ok, json} -> json
        {:error, reason} -> "Error: #{inspect(reason)}"
      end

    assign(socket, state_json: state)
  end

  defp load_enabled_providers do
    case NodeManager.get_enabled_providers() do
      map when is_map(map) ->
        # Filter to user-facing providers only
        user_facing = Map.keys(PluginSchema.providers())

        map
        |> Enum.filter(fn {k, _v} ->
          key = if is_atom(k), do: Atom.to_string(k), else: k
          key in user_facing
        end)
        |> Enum.map(fn {k, _v} ->
          key = if is_atom(k), do: Atom.to_string(k), else: k
          {key, PluginSchema.provider(key)}
        end)
        |> Enum.filter(fn {_k, schema} -> not is_nil(schema) end)
        |> Map.new()

      _ ->
        # Fall back to all user-facing providers
        PluginSchema.providers()
    end
  end

  defp extract_provider_settings(nil, _form), do: %{}

  defp extract_provider_settings(provider_schema, form) do
    Enum.reduce(provider_schema.fields, %{}, fn field, acc ->
      raw = Map.get(form, "field_#{field.name}", "")

      value =
        case field.type do
          :integer ->
            case Integer.parse(raw) do
              {n, ""} -> n
              _ -> nil
            end

          :boolean ->
            raw == "true"

          :json ->
            case Jason.decode(raw) do
              {:ok, parsed} -> parsed
              _ -> if raw == "", do: nil, else: raw
            end

          _ ->
            if raw == "", do: nil, else: raw
        end

      if is_nil(value), do: acc, else: Map.put(acc, field.name, value)
    end)
  end

  defp generate_plugin_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp flat_bindings(bindings) when is_map(bindings) do
    Enum.flat_map(bindings, fn {trigger, plugin_list} ->
      list = if is_list(plugin_list), do: plugin_list, else: []

      Enum.map(list, fn entry ->
        {plugin_id, binding} =
          case entry do
            {pid, b} -> {pid, b}
            [pid, b] -> {pid, b}
            _ -> {inspect(entry), %{}}
          end

        %{
          plugin_id: to_string(plugin_id),
          trigger: to_string(trigger),
          provider: get_binding_provider(binding),
          position: get_binding_position(binding)
        }
      end)
    end)
  end

  defp flat_bindings(_), do: []

  defp get_binding_provider(binding) when is_map(binding) do
    provider = Map.get(binding, :provider) || Map.get(binding, "provider")

    cond do
      is_nil(provider) -> "unknown"
      is_struct(provider) -> inspect(provider.__struct__)
      is_atom(provider) -> Atom.to_string(provider)
      true -> inspect(provider)
    end
  end

  defp get_binding_provider(_), do: "unknown"

  defp get_binding_position(binding) when is_map(binding) do
    Map.get(binding, :position) || Map.get(binding, "position") || 0
  end

  defp get_binding_position(_), do: 0
end
