defmodule FlezhaUiWeb.DashboardLive do
  use FlezhaUiWeb, :live_view

  # The data-plane summary reads its rates from snapshot deltas, so the screen
  # ticks at the rate those deltas are worth measuring over.
  use FlezhaUiWeb.Live.Refresh,
    every: 2_000,
    on_events: [:runner_connected, :runner_disconnected]

  use FlezhaUiWeb.Topology

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Topology

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> assign(page_title: "Dashboard", ns_param: nil)
     |> Topology.init()}
  end

  # The graph's namespace is carried in the query string, so a selection is a
  # link someone can send to whoever is on call.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(ns_param: params["ns"]) |> refresh()}
  end

  @impl true
  def handle_event("select_namespace", %{"ns" => ns}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?#{[ns: ns]}")}
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    stats = load_stats(socket.assigns.flezha_token)
    namespace = resolve_namespace(socket.assigns.ns_param, stats.namespaces)

    socket
    |> assign(stats: stats, namespace: namespace)
    |> Topology.load_summary(namespace)
  end

  # An `?ns=` naming a namespace the controller no longer has falls back rather
  # than showing an empty graph for a namespace that is not there.
  defp resolve_namespace(requested, namespaces) do
    sorted = Enum.sort(namespaces)

    if requested in sorted, do: requested, else: List.first(sorted)
  end

  defp load_stats(token) do
    node = NodeManager.connected_node()
    transport = System.get_env("FLEZHA_TRANSPORT", "uds")
    scope = NodeManager.token_scope(token)

    {namespaces, known_namespaces, operatives, runners, plugins, provider_count, error} =
      if node do
        {ns_list, ns_error} = NodeManager.scoped_namespaces(token)

        # The count is the same population the namespace listing shows, derived
        # by the same function, so the two screens cannot disagree. The
        # selector below stays on running hubs: a declared namespace with no
        # hub has no data plane to graph.
        known =
          NodeManager.declared_namespaces()
          |> NodeManager.ok_or([])
          |> NodeManager.known_namespace_names(ns_list, scope)

        # One registry dump per namespace, carrying health — the per-namespace
        # id list it replaced could only ever answer "how many".
        operatives =
          Enum.flat_map(ns_list, fn ns ->
            ns |> NodeManager.operative_rows() |> NodeManager.ok_or([])
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

        {ns_list, known, operatives, runners, plugins, provider_count, ns_error}
      else
        {[], [], [], [], %{}, 0, :node_not_connected}
      end

    %{
      node: node,
      transport: transport,
      namespace_count: length(known_namespaces),
      namespaces: namespaces,
      operative_count: length(operatives),
      operative_health: NodeManager.health_counts(operatives),
      unplaced_count: length(NodeManager.unplaced_rows(operatives)),
      runners: runners,
      plugin_count: map_size(plugins),
      provider_count: provider_count,
      token_scope: scope,
      error: error
    }
  end
end
