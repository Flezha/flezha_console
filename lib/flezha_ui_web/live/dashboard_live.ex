defmodule FlezhaUiWeb.DashboardLive do
  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000

  alias FlezhaUi.Service.EventBridge
  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventBridge.topic())
      schedule_refresh()
    end

    {:ok, assign(socket, stats: load_stats(), page_title: "Dashboard")}
  end

  @impl true
  def handle_info({:flezha_event, event, _data}, socket)
      when event in [:runner_connected, :runner_disconnected] do
    {:noreply, refresh(socket)}
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket), do: assign(socket, stats: load_stats())

  defp load_stats do
    node = NodeManager.connected_node()
    transport = System.get_env("FLEZHA_TRANSPORT", "uds")

    {namespaces, operatives, runners, plugins, provider_count, error} =
      if node do
        {ns_list, ns_error} =
          case NodeManager.list_namespaces() do
            {:ok, list} -> {list, nil}
            {:error, reason} -> {[], reason}
          end

        operatives =
          Enum.flat_map(ns_list, fn ns ->
            ns |> NodeManager.list_operatives() |> NodeManager.ok_or([])
          end)

        runners =
          Enum.flat_map(ns_list, fn ns ->
            ns
            |> NodeManager.list_runners()
            |> NodeManager.ok_or([])
            |> Enum.map(&%{id: NodeManager.identifier_id(&1), namespace: ns})
          end)

        plugins =
          case NodeManager.get_plugins() do
            map when is_map(map) -> map
            _ -> %{}
          end

        provider_count = NodeManager.get_provider_info() |> NodeManager.ok_or([]) |> length()

        {ns_list, operatives, runners, plugins, provider_count, ns_error}
      else
        {[], [], [], %{}, 0, :node_not_connected}
      end

    %{
      node: node,
      transport: transport,
      namespace_count: length(namespaces),
      namespaces: namespaces,
      operative_count: length(operatives),
      runners: runners,
      plugin_count: map_size(plugins),
      provider_count: provider_count,
      error: error
    }
  end
end
