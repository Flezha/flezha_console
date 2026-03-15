defmodule FlezhaUiWeb.PluginLive do
  use FlezhaUiWeb, :live_view

  alias FlezhaUi.Service.NodeManager

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)

    {:ok,
     assign(socket,
       plugins: load_plugins(),
       available_providers: load_available_providers(),
       confirm_disable: nil,
       page_title: "Plugins"
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)

    {:noreply,
     assign(socket, plugins: load_plugins(), available_providers: load_available_providers())}
  end

  @impl true
  def handle_event("confirm_disable", %{"plugin_id" => plugin_id}, socket) do
    {:noreply, assign(socket, confirm_disable: plugin_id)}
  end

  @impl true
  def handle_event("cancel_disable", _params, socket) do
    {:noreply, assign(socket, confirm_disable: nil)}
  end

  @impl true
  def handle_event("disable_plugin", %{"plugin_id" => plugin_id}, socket) do
    case NodeManager.disable_plugin(plugin_id) do
      {:ok, _} ->
        socket =
          socket
          |> assign(confirm_disable: nil, plugins: load_plugins())
          |> put_flash(:info, "Plugin #{plugin_id} disabled.")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_disable: nil)
         |> put_flash(:error, "Failed: #{inspect(reason)}")}
    end
  end

  defp load_plugins do
    case NodeManager.get_plugins() do
      map when is_map(map) ->
        Enum.map(map, fn {plugin_id, value} ->
          {module, ns, proc} = extract_plugin_info(value)

          %{
            id: to_string(plugin_id),
            module: inspect(module),
            namespace: ns,
            processor_id: proc
          }
        end)

      _ ->
        []
    end
  end

  # IOBindingPlugin.enable returns {IOBindingPlugin, {namespace, processor_id}}
  defp extract_plugin_info({module, {ns, proc_id}}) when is_binary(ns) do
    {module, ns, proc_id}
  end

  defp extract_plugin_info({module, info}) when is_map(info) do
    ns = Map.get(info, :namespace) || Map.get(info, "namespace")
    proc = Map.get(info, :processor_id) || Map.get(info, "processor_id")
    {module, ns, proc}
  end

  defp extract_plugin_info({module, _info}) do
    {module, nil, nil}
  end

  defp extract_plugin_info(other) do
    {inspect(other), nil, nil}
  end

  defp load_available_providers do
    case NodeManager.get_provider_info() do
      list when is_list(list) ->
        Enum.map(list, fn info ->
          id = to_string(Map.get(info, :id, ""))
          required = Map.get(info, :required_fields, [])
          internal = "recv_pid" in required

          %{
            id: id,
            label: humanize_id(id),
            module: Map.get(info, :module, "unknown"),
            type: Map.get(info, :type, :unknown),
            required_fields: required,
            optional_fields: Map.get(info, :optional_fields, []),
            internal: internal
          }
        end)

      _ ->
        []
    end
  end

  defp humanize_id(id) do
    id
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
