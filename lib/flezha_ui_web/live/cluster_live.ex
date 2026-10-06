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
    token = socket.assigns.flezha_token
    connected = NodeManager.connected_node()
    {names, load_error} = NodeManager.scoped_namespaces(token)
    namespaces = Enum.map(names, &describe_namespace(&1, token))

    assign(socket,
      load_error: load_error,
      connected_node: connected,
      cluster_nodes: cluster_nodes(namespaces, connected),
      namespaces: namespaces
    )
  end

  # The members are the nodes holding a hub for some namespace the caller can
  # see, as the controller answers them. The node this UI reached is always
  # one of them, even before it hosts a hub.
  defp cluster_nodes(namespaces, connected) do
    namespaces
    |> Enum.flat_map(& &1.hub_nodes)
    |> Enum.concat(List.wrap(connected))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{name: &1, connected?: &1 == connected})
  end

  defp describe_namespace(ns, token) do
    # The same rows `flz cluster status` reads, so the UI and the CLI cannot
    # disagree about where relays are or how healthy they are.
    rows = ns |> NodeManager.relay_rows(token) |> NodeManager.ok_or([])

    {status, status_error} = NodeManager.ok_or_error(NodeManager.cluster_status(ns, token), %{})
    hub_nodes = status |> Map.get(:nodes, []) |> Enum.map(& &1.node)
    recovery = Map.new(Map.get(status, :nodes, []), &{&1.node, &1.recovery_state})

    per_node =
      rows
      |> NodeManager.placed_rows()
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

    catalog = ns |> NodeManager.factory_catalog(token) |> NodeManager.ok_or([])
    factories_by_runner = NodeManager.factories_by_runner(catalog)

    runners =
      ns
      |> NodeManager.runners(token)
      |> NodeManager.ok_or([])
      |> Enum.map(fn runner ->
        id = NodeManager.identifier_id(runner)
        %{id: id, factories: Map.get(factories_by_runner, id, [])}
      end)

    %{
      name: ns,
      hub_nodes: hub_nodes,
      hub_error: status_error,
      runners: runners,
      # Namespace-derived and the same for every runner in it — the controller
      # mints it at connect, and it is what the audit log will name.
      runner_principal: NodeManager.runner_principal(ns, token),
      factories: catalog,
      per_node: per_node,
      health: NodeManager.health_counts(rows),
      unplaced: NodeManager.unplaced_rows(rows)
    }
  end
end
