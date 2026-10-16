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
    on_events: [:runner_connected, :runner_disconnected, :runner_dropped, :runner_readmitted]

  use FlezhaUiWeb.Live.RunnerActions

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> runner_actions_init()
     |> assign(page_title: "Cluster", selected_factory: nil, factory_runners: nil)
     |> assign(load_error: nil, connected_node: nil, cluster_nodes: [], namespaces: [])
     |> refresh()}
  end

  # A lookup, not a read: the catalog this screen already loaded per namespace
  # answers which runners serve each factory, so selecting one costs nothing.
  @impl true
  def handle_event("select_factory", %{"value" => key}, socket) do
    [ns, factory] = String.split(key, "/", parts: 2)

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
      cluster_nodes:
        namespaces |> Enum.flat_map(& &1.hub_nodes) |> NodeManager.cluster_nodes(connected),
      namespaces: namespaces
    )
  end

  @doc "A recovery state as an operator reads it, in its tone."
  def recovery(state), do: Words.say(:hub_recovery, state)

  # States that say the hub is serving, or that nothing can be said of it.
  @settled [:normal, :not_hosted, :unreachable, :unavailable, :unknown]

  @doc """
  The nodes whose copy of a namespace's hub is busy recovering rather than
  serving, with what it is doing. Empty when every hub serves or none can be
  read.
  """
  def hubs_not_serving(per_node) do
    for %{recovery: state, node: node} <- per_node,
        state not in @settled,
        do: {node, recovery(state).text}
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
      |> FlezhaUiWeb.Runners.rows(factories_by_runner)

    %{
      name: ns,
      hub_nodes: hub_nodes,
      hub_error: status_error,
      runners: runners,
      marks: ns |> NodeManager.dropped_runners(token) |> NodeManager.ok_or([]),
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
