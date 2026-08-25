defmodule FlezhaUiWeb.ClusterLive do
  @moduledoc """
  Where the control plane actually lives: cluster nodes, which node hosts each
  namespace's hub, and the runners serving each namespace.

  Subscribes to runner events so the fleet reflects a connect or disconnect
  without waiting for the refresh timer.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh,
    every: 5_000,
    on_events: [:runner_connected, :runner_disconnected]

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> assign(page_title: "Cluster", selected_factory: nil, factory_runners: nil)
     |> refresh()}
  end

  # A lookup, not a read: the catalog this screen already loaded per namespace
  # answers which runners serve each factory, so selecting one costs nothing.
  @impl true
  def handle_event("select_factory", %{"namespace" => ns, "factory" => factory}, socket) do
    runners =
      socket.assigns.namespaces
      |> Enum.find(%{}, &(&1.name == ns))
      |> Map.get(:factories, [])
      |> Enum.find(%{}, &(&1.id == factory))
      |> Map.get(:runners, [])

    {:noreply, assign(socket, selected_factory: {ns, factory}, factory_runners: runners)}
  end

  @impl true
  def handle_event("clear_factory", _params, socket) do
    {:noreply, assign(socket, selected_factory: nil, factory_runners: nil)}
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    connected = NodeManager.connected_node()
    {namespaces, load_error} = NodeManager.ok_or_error(NodeManager.list_namespaces(), [])

    assign(socket,
      load_error: load_error,
      connected_node: connected,
      cluster_nodes: cluster_nodes(connected),
      namespaces: Enum.map(namespaces, &describe_namespace/1)
    )
  end

  defp cluster_nodes(connected) do
    case NodeManager.controller_cluster_nodes() do
      {:ok, nodes} ->
        Enum.map(nodes, fn node -> %{name: node, connected?: node == connected} end)

      {:error, _reason} ->
        # A controller that cannot answer is still the node we are talking to.
        if connected, do: [%{name: connected, connected?: true}], else: []
    end
  end

  defp describe_namespace(ns) do
    # The same rows `flz cluster status` reads, so the UI and the CLI cannot
    # disagree about where operatives are or how healthy they are.
    rows = NodeManager.namespace_rows(ns)

    hub_nodes = NodeManager.ok_or(NodeManager.hub_nodes(ns), [])
    recovery = NodeManager.cluster_recovery(ns, hub_nodes)

    placed = NodeManager.placed_rows(rows)

    per_node =
      placed
      |> Enum.group_by(& &1[:node])
      |> Enum.map(fn {node, node_rows} ->
        %{
          node: node,
          count: length(node_rows),
          health: NodeManager.health_counts(node_rows),
          recovery: Map.get(recovery, node, :unavailable)
        }
      end)
      |> Enum.sort_by(&inspect(&1.node))

    describe_fleet(ns, rows, hub_nodes, per_node)
  end

  defp describe_fleet(ns, rows, hub_nodes, per_node) do
    catalog = ns |> NodeManager.factory_catalog() |> NodeManager.ok_or([])
    factories_by_runner = NodeManager.factories_by_runner(catalog)

    runners =
      ns
      |> NodeManager.active_runners()
      |> NodeManager.ok_or([])
      |> Enum.map(fn runner ->
        id = NodeManager.identifier_id(runner)
        %{id: id, factories: Map.get(factories_by_runner, id, [])}
      end)

    %{
      name: ns,
      hub_nodes: hub_nodes,
      runners: runners,
      # Namespace-derived and the same for every runner in it — the controller
      # mints it at connect, and it is what the audit log will name.
      runner_principal: NodeManager.runner_principal(ns),
      factories: catalog,
      per_node: per_node,
      health: NodeManager.health_counts(rows),
      unplaced: NodeManager.unplaced_rows(rows)
    }
  end
end
