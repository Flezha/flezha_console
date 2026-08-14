defmodule FlezhaUiWeb.ClusterLive do
  @moduledoc """
  Where the control plane actually lives: cluster nodes, which node hosts each
  namespace's hub, and the runners serving each namespace.

  Subscribes to runner events so the fleet reflects a connect or disconnect
  without waiting for the refresh timer.
  """

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

    {:ok,
     socket
     |> assign(page_title: "Cluster", selected_factory: nil, factory_runners: nil)
     |> refresh()}
  end

  @impl true
  def handle_info({:flezha_event, event, _data}, socket)
      when event in [:runner_connected, :runner_disconnected] do
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("select_factory", %{"namespace" => ns, "factory" => factory}, socket) do
    runners =
      ns
      |> NodeManager.runners_for_factory(factory)
      |> NodeManager.ok_or([])
      |> Enum.map(&NodeManager.identifier_id/1)

    {:noreply, assign(socket, selected_factory: {ns, factory}, factory_runners: runners)}
  end

  @impl true
  def handle_event("clear_factory", _params, socket) do
    {:noreply, assign(socket, selected_factory: nil, factory_runners: nil)}
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    connected = NodeManager.connected_node()

    case NodeManager.list_namespaces() do
      {:ok, namespaces} ->
        assign(socket,
          load_error: nil,
          connected_node: connected,
          cluster_nodes: cluster_nodes(connected),
          namespaces: Enum.map(namespaces, &describe_namespace/1)
        )

      {:error, reason} ->
        assign(socket,
          load_error: reason,
          connected_node: connected,
          cluster_nodes: cluster_nodes(connected),
          namespaces: []
        )
    end
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
    factories =
      ns
      |> NodeManager.list_factories()
      |> NodeManager.ok_or([])
      |> Enum.map(&NodeManager.identifier_id/1)
      |> Enum.sort()

    # One lookup per factory, then inverted — rather than asking the controller
    # once per runner-factory pair.
    factories_by_runner =
      Enum.reduce(factories, %{}, fn factory, acc ->
        ns
        |> NodeManager.runners_for_factory(factory)
        |> NodeManager.ok_or([])
        |> Enum.reduce(acc, fn runner, inner ->
          Map.update(inner, NodeManager.identifier_id(runner), [factory], &[factory | &1])
        end)
      end)

    runners =
      ns
      |> NodeManager.active_runners()
      |> NodeManager.ok_or([])
      |> Enum.map(fn runner ->
        id = NodeManager.identifier_id(runner)
        %{id: id, factories: factories_by_runner |> Map.get(id, []) |> Enum.sort()}
      end)

    %{
      name: ns,
      hub_nodes: NodeManager.ok_or(NodeManager.hub_nodes(ns), []),
      runners: runners,
      factories: factories
    }
  end
end
