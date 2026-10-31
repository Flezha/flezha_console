defmodule FlezhaConsoleWeb.RelayIndexLive do
  @moduledoc """
  Every relay the bound token can reach, across every namespace.

  "Where is everything, and what is unhealthy?" is a different question from
  "what is in this namespace", and it is the one an operator asks first when
  something is wrong. It is affordable because it reads only what it shows:
  one page per namespace, searched, filtered and sorted by the controller,
  whose rows carry their run and plugin count, and one liveness read naming
  the relays on it.

  It also carries the start form, so an operator reading "everything, anywhere"
  can act on it without first working out which namespace to navigate into. The
  form's factory catalog is read when it opens, so the listing itself stays
  flat.

  The same screen serves one namespace at `/namespaces/:ns/relays`. It is
  the same listing with the namespace filter already applied — taken from the
  path rather than from the form, so the address bar names the scope and the
  screen renders it as fixed rather than as something to clear.

  Relays starting, stopping and losing their runner arrive on the event feed
  as they happen; each one reloads the rows and goes on the event river,
  narrowed to the namespaces the token reaches.

  Each row carries its measured inbound rate and a sparkline, from the same
  liveness snapshot the Dashboard map reads, and activating a row inspects the
  relay in place.

  A partition group is one row however wide it is: its partitions' rates
  summed, their nodes and runners counted, and the partitions themselves
  listed as a paged listing of their own only when the operator opens the
  group.
  """

  use FlezhaConsoleWeb, :live_view

  use FlezhaConsoleWeb.Live.Refresh,
    every: 5_000,
    on_events: [:runner_connected, :runner_disconnected, :runner_dropped, :runner_readmitted],
    background: true

  use FlezhaConsoleWeb.Live.Launcher
  use FlezhaConsoleWeb.River
  use FlezhaConsoleWeb.Inspect, kinds: ~w(relay)

  alias FlezhaConsole.Format
  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.ListingView
  alias FlezhaConsoleWeb.Live.Sections
  alias FlezhaConsoleWeb.Topology

  @listing "relay-rows"

  # The namespace filter picks which namespaces are read; every other filter,
  # the search and the sort are the controller's.
  @view ListingView.declare(
          search: :text,
          filters: [namespace: nil, health: :health, run: :run, runner: :runner],
          sorts: [id: "By id", severity: "Most severe first"]
        )

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> launcher_init(nil)
     |> Topology.init()
     |> river_init()
     |> assign(
       page_title: "Relays",
       loaded?: false,
       filters: ListingView.default(@view),
       rows: [],
       total: 0,
       unreachable: [],
       namespaces: [],
       load_error: nil,
       confirm_stop: nil,
       expanded: MapSet.new()
     )}
  end

  # The start form offers the namespaces this screen already listed, so asking
  # where to start costs no second read.
  @impl FlezhaConsoleWeb.Live.Launcher
  def launcher_namespaces(socket), do: {socket.assigns.namespaces, socket.assigns.load_error}

  # The URL is the filter state, not a copy of it: read whole from the params
  # every time, so clearing a filter clears it and the browser's back button
  # walks back through them. A scoped route's namespace comes from the path and
  # outranks anything the query string carries.
  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.scoped_namespace

    filters =
      @view
      |> ListingView.parse(params)
      |> then(&if(scope, do: Map.put(&1, "namespace", scope), else: &1))

    # Opening or closing an inspector patches the address too; it changes no
    # filter, so it reads nothing.
    socket =
      if filters == socket.assigns.filters and socket.assigns.loaded?,
        do: socket,
        else:
          socket
          |> assign(filters: filters, page_title: Layouts.scoped_title("Relays", scope))
          |> read_when_connected()

    {:noreply, inspect_params(socket, params)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = Map.merge(socket.assigns.filters, ListingView.parse(@view, params))
    {:noreply, push_patch(socket, to: filtered_path(socket.assigns.scoped_namespace, filters))}
  end

  def handle_event("toggle_group", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, expanded: expanded)}
  end

  @impl true
  def handle_event("confirm_stop", %{"relay_id" => id} = params, socket) do
    row = NodeManager.relay_row(socket.assigns.rows, id)
    namespace = params["namespace"] || (row && row.namespace)
    {:noreply, assign(socket, confirm_stop: namespace && %{relay: id, namespace: namespace})}
  end

  @impl true
  def handle_event("cancel_stop", _params, socket),
    do: {:noreply, assign(socket, confirm_stop: nil)}

  @impl true
  def handle_event("stop_relay", _params, %{assigns: %{confirm_stop: %{} = stop}} = socket) do
    socket = assign(socket, confirm_stop: nil)

    case NodeManager.stop_relay(stop.namespace, stop.relay, socket.assigns.flezha_token) do
      {:ok, answer} ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(:info, Format.relay_stopped(stop.relay, answer))
         |> push_patch(to: inspect_path(socket, nil))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason, "the stop"))}
    end
  end

  def handle_event("stop_relay", _params, socket), do: {:noreply, socket}

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_paused?(socket),
    do: FlezhaConsoleWeb.Live.Launcher.open?(socket) or socket.assigns.confirm_stop != nil

  @impl FlezhaConsoleWeb.Inspect
  def inspect_context(socket, {"relay", key}) do
    {namespace, id} = row_key(socket, key)

    row =
      socket.assigns.rows
      |> Enum.flat_map(&[&1 | &1[:members] || []])
      |> Enum.find(&(to_string(&1.id) == id and &1.namespace == namespace))

    state = socket.assigns.topology_state
    key = row && {row.namespace, id}

    %{
      row: row,
      rate: Map.get(state.rates, key),
      history: state.history |> Map.get(key, []) |> Enum.reverse()
    }
  end

  def inspect_context(_socket, _selection), do: %{}

  defp row_key(%{assigns: %{scoped_namespace: scope}}, id) when is_binary(scope), do: {scope, id}

  defp row_key(_socket, key) do
    case String.split(key, "/", parts: 2) do
      [namespace, id] -> {namespace, id}
      [id] -> {nil, id}
    end
  end

  @doc "How a row is named in `?inspect=`: its id, with its namespace on an unscoped screen."
  def inspect_id(row, nil), do: "#{row.namespace}/#{row.id}"
  def inspect_id(row, _scope), do: to_string(row.id)

  # A blank filter is left out entirely, and a scoped screen's namespace is
  # already a path segment — repeating it in the query string would give the
  # same scope two places to disagree from.
  @doc false
  def filtered_path(scope, filters) do
    query =
      @view
      |> ListingView.query(filters)
      |> then(&if(scope, do: Map.delete(&1, "namespace"), else: &1))

    if scope,
      do: ~p"/namespaces/#{scope}/relays?#{query}",
      else: ~p"/relays?#{query}"
  end

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_read(socket) do
    %{flezha_token: token, scoped_namespace: scope, filters: filters} = socket.assigns
    opts = ListingView.opts(@view, filters, Sections.limit(socket.assigns.paging, @listing))
    fn -> read(token, scope, filters, opts) end
  end

  # One page per namespace read, merged by namespace, and the rates of the
  # relays on it. A scoped screen reads its one namespace rather than reading
  # them all and discarding the rest — and a scope the token cannot reach
  # lists nothing.
  defp read(token, scope, filters, opts) do
    {namespaces, load_error} = NodeManager.scoped_namespaces(token)

    reads =
      namespaces
      |> listed(scope, filters["namespace"])
      |> Enum.map(&{&1, NodeManager.relay_list(&1, token, opts)})

    rows =
      reads
      |> Enum.flat_map(&namespace_rows/1)
      |> Enum.take(opts[:limit])
      |> Enum.map(&on_runner(&1, filters["runner"]))

    %{
      namespaces: Enum.sort(namespaces),
      load_error: load_error || Enum.find_value(reads, &read_error/1),
      rows: rows,
      total: reads |> Enum.map(fn {_ns, read} -> read_total(read) end) |> Enum.sum(),
      unreachable: reads |> Enum.map(&elem(&1, 1)) |> NodeManager.unreachable(),
      rates: Topology.read_rates(token, Enum.flat_map(rows, &rate_keys/1))
    }
  end

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_apply(socket, {:ok, read}) do
    socket
    |> assign(
      loaded?: true,
      namespaces: read.namespaces,
      rows: read.rows,
      total: read.total,
      unreachable: read.unreachable,
      load_error: read.load_error
    )
    |> Topology.apply_rates(read.rates, group_keys(read.rows))
  end

  def refresh_apply(socket, {:exit, _reason}),
    do: assign(socket, loaded?: true, load_error: :read_failed)

  @doc false
  def listing_grown(socket, @listing), do: refresh(socket)
  def listing_grown(socket, _id), do: socket

  defp listed(namespaces, nil, ""), do: namespaces
  defp listed(namespaces, nil, chosen), do: listed(namespaces, chosen, "")
  defp listed(namespaces, scope, _chosen), do: if(scope in namespaces, do: [scope], else: [])

  defp read_total({:ok, %{total: total}}), do: total
  defp read_total(_failed), do: 0

  defp read_error({_ns, {:error, reason}}), do: reason
  defp read_error(_read), do: nil

  # A namespace's page, each row with its namespace and whether the controller
  # holding it answered.
  defp namespace_rows({namespace, read}) do
    unanswered = NodeManager.unreachable([read])

    decorate = fn row ->
      row
      |> Map.put(:namespace, namespace)
      |> Map.put(:unanswered?, row[:node] != nil and row[:node] in unanswered)
    end

    read
    |> NodeManager.ok_or([])
    |> Enum.map(fn
      %{members: [_ | _] = members} = group ->
        group |> decorate.() |> Map.put(:members, Enum.map(members, decorate))

      row ->
        decorate.(row)
    end)
  end

  # A group spans runners, so asked about one it keeps the partitions there.
  defp on_runner(%{members: [_ | _] = members} = group, runner) when runner not in [nil, ""],
    do: %{group | members: Enum.filter(members, &(to_string(&1[:runner]) == runner))}

  defp on_runner(row, _runner), do: row

  # A group's rate is its partitions' summed, so its members are read.
  defp rate_keys(row), do: Enum.map(row[:members] || [row], &rate_key(row.namespace, &1))

  defp rate_key(namespace, row), do: {namespace, to_string(row.id)}

  defp group_keys(rows) do
    for %{members: [_ | _] = members} = group <- rows,
        into: %{},
        do: {rate_key(group.namespace, group), Enum.map(members, &rate_key(group.namespace, &1))}
  end

  # A scoped route's namespace comes from the path, so it is not a filter the
  # operator chose.
  defp filtered?(filters, scope) do
    filters
    |> Map.drop(["sort" | if(scope, do: ["namespace"], else: [])])
    |> Enum.any?(fn {_key, value} -> value != "" end)
  end

  @doc """
  The rows drawn under `row`: a group's partitions while it is open, as a
  paged listing of their own.
  """
  def open_members(row, expanded) do
    if row[:partitions] && MapSet.member?(expanded, group_key(row)),
      do: {"group-#{row.namespace}-#{row.id}", row.members}
  end

  @doc "How an open group is remembered."
  def group_key(row), do: "#{row.namespace}/#{row.id}"

  @doc "A row's measured rate; a group's is its partitions' summed."
  def rate_of(row, state), do: Map.get(state.rates, rate_key(row.namespace, row))

  @doc "A row's rate history, oldest first; a group's sums its partitions' tick by tick."
  def history_of(row, state),
    do: state.history |> Map.get(rate_key(row.namespace, row), []) |> Enum.reverse()

  @doc """
  Where a row's relays sit by `key` (`:node` or `:runner`): `{:one, value}`
  when they share one, or `{:many, distinct, without}` for a group whose
  partitions spread over several, `without` counting those holding none.
  """
  def spread(%{partitions: _, members: members}, key) do
    {held, without} = members |> Enum.map(&Map.get(&1, key)) |> Enum.split_with(&(&1 != nil))

    case {Enum.uniq(held), without} do
      {[one], []} -> {:one, one}
      {[], _all} -> {:one, nil}
      {distinct, without} -> {:many, length(distinct), length(without)}
    end
  end

  def spread(row, key), do: {:one, row[key]}

  # A fixed box, so the column keeps its width as the figures change.
  attr :id, :string, required: true
  attr :rate, :map, default: nil
  attr :history, :list, required: true

  defp rate_cell(assigns) do
    ~H"""
    <span class="fcon-rate-cell" data-testid={"relay-rate-#{@id}"}>
      <span class="fcon-rate-spark">
        <.sparkline samples={@history} key={:in} width={56} height={16} testid={"relay-spark-#{@id}"} />
      </span>
      <span class="fcon-rate-figures">
        <span class="fcon-rate">{(@rate && Topology.rate_label(@rate.in)) || "—"}</span>
        <span :if={@rate[:bytes_in]} class="fcon-figures">
          {Topology.byte_rate_label(@rate.bytes_in)}
        </span>
      </span>
    </span>
    """
  end

  @doc "How many of a group's partitions are not healthy."
  def unwell(members), do: Enum.count(members, &(Words.tone(:health, &1.health) != :positive))

  @doc """
  The health values offered as filters, so the list cannot drift from the badge.

  Every verdict the controller answers is one of them, `recovering` and
  `halted` included. `:suspended` too: the Convergence Loop ranks suspension in
  the health ladder, so filtering to suspended relays is a health filter and
  costs nothing beyond the listing's own read.
  """
  def health_options, do: NodeManager.health_verdicts()

  @doc "The runs offered as filters: every run a relay can have."
  def run_options, do: ~w(flow steps)

  @doc "The sorts the listing offers."
  def sort_options, do: ListingView.sorts(@view)
end
