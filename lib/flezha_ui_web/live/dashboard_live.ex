defmodule FlezhaUiWeb.DashboardLive do
  use FlezhaUiWeb, :live_view

  alias FlezhaUi.Service.NodeManager

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok, assign(socket, stats: load_stats(), page_title: "Dashboard")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign(socket, stats: load_stats())}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp load_stats do
    node = NodeManager.connected_node()
    transport = System.get_env("FLEZHA_TRANSPORT", "uds")

    {namespaces, processors, compute_engines, plugins, provider_count} =
      if node do
        ns_list =
          case NodeManager.list_namespaces() do
            list when is_list(list) -> list
            _ -> []
          end

        processors =
          Enum.flat_map(ns_list, fn ns ->
            case NodeManager.list_processors(ns) do
              {:ok, list} -> list
              _ -> []
            end
          end)

        ces =
          Enum.flat_map(ns_list, fn ns ->
            case NodeManager.list_compute_engines(ns) do
              {:ok, list} -> Enum.map(list, &%{id: &1, namespace: ns})
              _ -> []
            end
          end)

        plugins =
          case NodeManager.get_plugins() do
            map when is_map(map) -> map
            _ -> %{}
          end

        provider_count =
          case NodeManager.get_provider_info() do
            list when is_list(list) -> length(list)
            _ -> 0
          end

        {ns_list, processors, ces, plugins, provider_count}
      else
        {[], [], [], %{}, 0}
      end

    %{
      node: node,
      transport: transport,
      namespace_count: length(namespaces),
      namespaces: namespaces,
      processor_count: length(processors),
      compute_engines: compute_engines,
      plugin_count: map_size(plugins),
      provider_count: provider_count
    }
  end
end
