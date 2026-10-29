defmodule FlezhaConsoleWeb.ClusterLive do
  @moduledoc """
  Where the control plane actually lives: a row of tiles for everything the
  operator's token reaches, cluster nodes, which node hosts each namespace's
  hub, and the runners serving each namespace.

  The tiles count what this screen reads, except relay health, open problems
  and durability breaches, which come from the shell pulse every screen keeps.

  Subscribes to runner events so the fleet reflects a connect or disconnect
  without waiting for the refresh timer.
  """

  use FlezhaConsoleWeb, :live_view

  use FlezhaConsoleWeb.Live.Refresh,
    every: 5_000,
    on_events: [:runner_connected, :runner_disconnected, :runner_dropped, :runner_readmitted],
    background: true

  use FlezhaConsoleWeb.Live.RunnerActions

  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.Attention

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> runner_actions_init()
     |> assign(page_title: "Cluster", selected_factory: nil, factory_runners: nil)
     |> assign(load_error: nil, connected_node: nil, cluster_nodes: [], namespaces: [])
     |> assign(runner_count: 0, controller_status: nil, unreachable: [])
     |> read_now()}
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

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_read(socket) do
    token = socket.assigns.flezha_token
    fn -> read(token) end
  end

  defp read(token) do
    connected = NodeManager.connected_node()
    {names, load_error} = NodeManager.scoped_namespaces(token)
    namespaces = Enum.map(names, &describe_namespace(&1, token))
    controllers = NodeManager.controllers(token)
    status = NodeManager.controller_status(token)

    %{
      load_error: load_error,
      connected_node: connected,
      cluster_nodes:
        namespaces
        |> Enum.flat_map(& &1.hub_nodes)
        |> Enum.concat(controllers |> NodeManager.ok_or([]) |> Enum.map(& &1.node))
        |> NodeManager.cluster_nodes(connected),
      namespaces: namespaces,
      # One runner may answer for more than one namespace; it is still one.
      runner_count:
        namespaces |> Enum.flat_map(& &1.runners) |> Enum.uniq_by(& &1.id) |> length(),
      controller_status: status,
      unreachable:
        NodeManager.unreachable([controllers, status | Enum.flat_map(namespaces, & &1.answers)])
    }
  end

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_apply(socket, {:ok, read}), do: assign(socket, read)
  def refresh_apply(socket, {:exit, _reason}), do: assign(socket, load_error: :read_failed)

  defp health_total(health), do: health |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp nodes_said([]), do: {:negative, "Unreachable", "None reachable"}

  defp nodes_said(nodes) do
    case Enum.find(nodes, & &1.connected?) do
      nil -> {:negative, "Disconnected", "This console is connected to none of them"}
      node -> {:positive, "Connected", "This console is connected to #{node.name}"}
    end
  end

  defp problems_said([]), do: {:positive, "Clear", "Nothing needs attention"}

  defp problems_said(items) do
    tone = FlezhaConsoleWeb.Attention.worst(items)
    verdict = if tone == :negative, do: "Urgent", else: "Attention"
    {tone, verdict, Words.need_attention(length(items), "problem")}
  end

  defp controller_said(nil, _breaches, _status),
    do: {:negative, "Down", "This console cannot reach it"}

  defp controller_said(_node, breaches, _status) when breaches > 0,
    do:
      {:negative, "Breach",
       "#{Words.count(breaches, "durability breach", "durability breaches")} past their RPO"}

  defp controller_said(_node, _breaches, {:ok, %{rows: rows, unreachable: [_ | _] = missing}}),
    do: {:warning, "Partial", answered_words(length(rows), length(rows) + length(missing))}

  defp controller_said(_node, _breaches, {:ok, %{rows: rows}}) do
    case rows |> Enum.map(& &1[:durability_posture]) |> Enum.uniq() do
      [posture] ->
        said = Words.say(:durability_posture, posture)
        {if(said.tone == :neutral, do: :positive, else: said.tone), "Up", said.text}

      _mixed ->
        {:positive, "Up", "The controllers keep different durability postures"}
    end
  end

  defp controller_said(_node, _breaches, _status), do: {:positive, "Up", "Connected"}

  attr :selected, :any, required: true, doc: "`{namespace, factory}`"

  # The looked-up factory, linked to its page.
  defp factory_link(%{selected: {ns, factory}} = assigns) do
    assigns = assign(assigns, ns: ns, factory: factory)

    ~H"""
    <.link
      navigate={~p"/namespaces/#{@ns}/factories/#{@factory}"}
      class="fcon-num"
      data-testid="factory-page-link"
    >
      {@factory}
    </.link>
    """
  end

  @doc """
  How many of a namespace's relays have no live node, naming those among its
  most severe: "3 relays have no live node: a, b, and 1 more".
  """
  def unplaced_words(%{unplaced_count: count, unplaced: named}) do
    said = "#{Words.count(count, "relay")} #{if count == 1, do: "has", else: "have"} no live node"

    case Enum.map(named, &to_string(&1.id)) do
      [] ->
        said

      ids when count > length(ids) ->
        "#{said}: #{Enum.join(ids, ", ")}, and #{count - length(ids)} more"

      ids ->
        "#{said}: #{Enum.join(ids, ", ")}"
    end
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
    # The controller's own per-node count, as `flz cluster status` reads it,
    # so the UI and the CLI cannot disagree about where relays are; the
    # namespace's health and its most severe relays from the relay summary.
    read_status = NodeManager.cluster_status(ns, token)
    read_page = NodeManager.relay_list(ns, token, Attention.relay_opts())
    page = Attention.page(read_page)

    {status, status_error} = NodeManager.ok_or_error(read_status, %{})
    hub_nodes = status |> Map.get(:nodes, []) |> Enum.map(& &1.node)

    per_node =
      status
      |> Map.get(:nodes, [])
      |> Enum.filter(&((&1[:relay_count] || 0) > 0))
      |> Enum.map(fn row ->
        %{node: row.node, count: row.relay_count, recovery: row[:recovery_state] || :unavailable}
      end)
      |> Enum.sort_by(&inspect(&1.node))

    read_catalog = NodeManager.factory_catalog(ns, token)
    catalog = NodeManager.ok_or(read_catalog, [])
    factories_by_runner = NodeManager.factories_by_runner(catalog)

    runners =
      ns
      |> NodeManager.runners(token)
      |> NodeManager.ok_or([])
      |> FlezhaConsoleWeb.Runners.rows(factories_by_runner)

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
      health: page.health,
      unplaced: NodeManager.unplaced_rows(page.rows),
      unplaced_count: Map.get(status, :unplaced_relays, 0),
      answers: [read_page, read_status, read_catalog]
    }
  end
end
