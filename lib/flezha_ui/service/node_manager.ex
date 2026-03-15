defmodule FlezhaUi.Service.NodeManager do
  def connected_node do
    Node.list(:connected) |> List.first()
  end

  def erpc_call(module, function, args) do
    node = connected_node()

    if is_atom(node) and not is_nil(node) do
      try do
        :erpc.call(node, module, function, args)
      catch
        :error, reason -> {:error, reason}
      end
    else
      {:error, :node_not_connected}
    end
  end

  # ---- Namespace / Processor API ----

  def list_namespaces() do
    erpc_call(Flezha, :list_namespaces, [])
  end

  def list_processors(namespace) do
    erpc_call(Flezha, :list_processors, [namespace])
  end

  def list_compute_engines(namespace) do
    erpc_call(Flezha, :list_compute_engines, [namespace])
  end

  def start_processor(namespace, id, factory_id, init_values \\ %{}, opts \\ []) do
    builder = %{id: id, factory_id: factory_id, init_values: init_values, opts: opts}
    erpc_call(Flezha, :start_processor, [namespace, builder])
  end

  def stop_processor(namespace, processor_id) do
    erpc_call(Flezha, :stop_processor, [namespace, processor_id])
  end

  def processor_state(namespace, processor_id) do
    erpc_call(Flezha, :processor_state, [namespace, processor_id])
  end

  def get_overwatch_state(namespace, processor_id) do
    erpc_call(Flezha.Service.ProcessorManager, :get_overwatch_state, [namespace, processor_id])
  end

  # ---- Plugin API ----

  def enable_plugin(plugin_id, plugin_map) do
    erpc_call(Flezha, :enable_plugin, [plugin_id, plugin_map])
  end

  def disable_plugin(plugin_id) do
    erpc_call(Flezha, :disable_plugin, [plugin_id])
  end

  def get_plugins() do
    erpc_call(Flezha.Service.PluginManager, :get_plugins, [])
  end

  def get_enabled_providers() do
    erpc_call(Flezha.Service.ConfigManager, :get_enabled_plugins, [])
  end
end
