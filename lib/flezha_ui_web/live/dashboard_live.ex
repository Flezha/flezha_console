defmodule FlezhaUiWeb.DashboardLive do
  use FlezhaUiWeb, :live_view

  # The data-plane summary reads its rates from snapshot deltas, so the screen
  # ticks at the rate those deltas are worth measuring over.
  use FlezhaUiWeb.Live.Refresh,
    every: 2_000,
    on_events: [:runner_connected, :runner_disconnected, :runner_dropped, :runner_readmitted]

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
    socket = Layouts.keep_namespace(socket, params["ns"])

    {:noreply,
     socket |> assign(ns_param: params["ns"] || socket.assigns.shell_namespace) |> refresh()}
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

    {catalog, relays, runners, plugin_count, provider_count, error} =
      if node do
        {catalog, error} = NodeManager.ok_or_error(NodeManager.list_namespaces(token), [])
        running = for %{namespace: ns, running: true} <- catalog, do: to_string(ns)

        # One listing per namespace, carrying health — never a call per relay.
        relays =
          Enum.flat_map(running, fn ns ->
            ns |> NodeManager.relay_rows(token) |> NodeManager.ok_or([])
          end)

        runners =
          Enum.flat_map(running, fn ns ->
            ns
            |> NodeManager.runners(token)
            |> NodeManager.ok_or([])
            |> Enum.map(&%{id: NodeManager.identifier_id(&1), pid: &1[:pid], namespace: ns})
          end)

        plugin_count =
          running
          |> Enum.flat_map(&(&1 |> NodeManager.plugins(token) |> NodeManager.ok_or([])))
          |> length()

        provider_count =
          token
          |> NodeManager.providers()
          |> NodeManager.ok_or(%{providers: []})
          |> Map.get(:providers)
          |> length()

        {catalog, relays, runners, plugin_count, provider_count, error}
      else
        {[], [], [], 0, 0, :node_not_connected}
      end

    %{
      node: node,
      transport: transport,
      # Every namespace the catalog lists, declared or running, as the
      # namespace listing counts them. The selector below stays on running
      # hubs: a namespace with no hub has no data plane to graph.
      namespace_count: length(catalog),
      namespaces: for(%{namespace: ns, running: true} <- catalog, do: to_string(ns)),
      relay_count: length(relays),
      relay_health: NodeManager.health_counts(relays),
      unplaced_count: length(NodeManager.unplaced_rows(relays)),
      runners: runners,
      plugin_count: plugin_count,
      provider_count: provider_count,
      scoped_to: scoped_to(token),
      error: error
    }
  end

  # The namespace a token is bound to, when it is bound to one: the controller
  # narrows what it lists to it, so the selector says why it offers no other.
  defp scoped_to(token) do
    case NodeManager.authz_status(token) do
      %{namespace: namespace} when namespace not in [nil, "_system"] -> to_string(namespace)
      _all_or_unbound -> nil
    end
  end
end
