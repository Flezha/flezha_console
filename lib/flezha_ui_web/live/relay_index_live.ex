defmodule FlezhaUiWeb.RelayIndexLive do
  @moduledoc """
  Every relay the bound token can reach, across every namespace.

  "Where is everything, and what is unhealthy?" is a different question from
  "what is in this namespace", and it is the one an operator asks first when
  something is wrong. It is affordable because the per-namespace read is flat:
  one listing call, one plugins call and one registry call per namespace, never
  a call per relay.

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
  liveness snapshot the Home map reads, and activating a row inspects the
  relay in place.

  A partition group is one row however wide it is: its partitions' rates
  summed, their nodes and runners counted, and the partitions themselves
  listed as rows of their own only when the operator opens the group.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh,
    every: 5_000,
    on_events: [:runner_connected, :runner_disconnected, :runner_dropped, :runner_readmitted]

  use FlezhaUiWeb.Live.Launcher
  use FlezhaUiWeb.River
  use FlezhaUiWeb.Inspect, kinds: ~w(relay)

  alias FlezhaUi.Format
  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Topology

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
       filters: %{"namespace" => "", "health" => "", "run" => "", "runner" => ""},
       rows: [],
       run_options: [],
       namespaces: [],
       load_error: nil,
       confirm_stop: nil,
       expanded: MapSet.new()
     )}
  end

  # The start form offers the namespaces this screen already listed, so asking
  # where to start costs no second read.
  @impl FlezhaUiWeb.Live.Launcher
  def launcher_namespaces(socket), do: {socket.assigns.namespaces, socket.assigns.load_error}

  # The URL is the filter state, not a copy of it: read whole from the params
  # every time, so clearing a filter clears it and the browser's back button
  # walks back through them. A scoped route's namespace comes from the path and
  # outranks anything the query string carries.
  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.scoped_namespace

    filters =
      ~w(namespace health run runner)
      |> Map.new(fn key -> {key, to_string(params[key] || "")} end)
      |> then(&if(scope, do: Map.put(&1, "namespace", scope), else: &1))

    # Opening or closing an inspector patches the address too; it changes no
    # filter, so it reads nothing.
    socket =
      if filters == socket.assigns.filters and socket.assigns.loaded?,
        do: socket,
        else:
          socket
          |> assign(filters: filters, page_title: Layouts.scoped_title("Relays", scope))
          |> refresh_when_connected()

    {:noreply, inspect_params(socket, params)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = Map.merge(socket.assigns.filters, params)

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

  @impl FlezhaUiWeb.Live.Refresh
  def refresh_paused?(socket),
    do: FlezhaUiWeb.Live.Launcher.open?(socket) or socket.assigns.confirm_stop != nil

  @impl FlezhaUiWeb.Inspect
  def inspect_context(socket, {"relay", key}) do
    {namespace, id} = row_key(socket, key)

    row =
      socket.assigns.rows
      |> Enum.flat_map(&[&1 | &1[:members] || []])
      |> Enum.find(&(to_string(&1.id) == id and &1.namespace == namespace))

    state = socket.assigns.topology_state

    %{
      row: row,
      rate: Map.get(state.rates, id),
      history: state.history |> Map.get(id, []) |> Enum.reverse()
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
      filters
      |> then(&if(scope, do: Map.delete(&1, "namespace"), else: &1))
      |> Enum.reject(fn {_key, value} -> to_string(value) == "" end)
      |> Map.new()

    if scope,
      do: ~p"/namespaces/#{scope}/relays?#{query}",
      else: ~p"/relays?#{query}"
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token

    {namespaces, load_error} = NodeManager.scoped_namespaces(token)

    # A scoped screen reads its one namespace rather than reading them all and
    # discarding the rest — and a scope the token cannot reach lists nothing.
    rows =
      namespaces
      |> listed(socket.assigns.scoped_namespace)
      |> Enum.flat_map(&namespace_rows(&1, token))

    socket
    |> assign(
      loaded?: true,
      namespaces: Enum.sort(namespaces),
      rows: filter(rows, socket.assigns.filters),
      run_options: run_options(rows),
      load_error: load_error
    )
    |> Topology.load_rates(
      Enum.flat_map(rows, fn row -> Enum.map([row | row[:members] || []], &to_string(&1.id)) end)
    )
  end

  defp listed(namespaces, nil), do: namespaces
  defp listed(namespaces, scope), do: if(scope in namespaces, do: [scope], else: [])

  defp namespace_rows(namespace, token) do
    plugins =
      namespace
      |> NodeManager.relay_plugins(token)
      |> NodeManager.ok_or([])
      |> NodeManager.plugin_counts()

    runs = namespace |> NodeManager.relay_runs(token) |> NodeManager.ok_or(%{})

    decorate = fn row ->
      # A group row is no registry entry of its own; its run and bindings are
      # its first member's, which every member shares.
      id = row |> Map.get(:members, [row]) |> hd() |> Map.fetch!(:id) |> to_string()

      row
      |> Map.put(:namespace, namespace)
      |> Map.put(:run, Map.get(runs, id))
      |> Map.put(:plugins, Map.get(plugins, id, 0))
    end

    namespace
    |> NodeManager.relay_list(token)
    |> NodeManager.ok_or([])
    |> Enum.map(fn
      %{members: [_ | _] = members} = group ->
        group
        |> decorate.()
        |> Map.put(:members, members |> NodeManager.decorate_health() |> Enum.map(decorate))

      row ->
        decorate.(row)
    end)
  end

  # A scoped route's namespace comes from the path, so it is not a filter the
  # operator chose.
  defp filtered?(filters, scope) do
    filters
    |> then(&if(scope, do: Map.delete(&1, "namespace"), else: &1))
    |> Enum.any?(fn {_key, value} -> value != "" end)
  end

  defp filter(rows, filters) do
    rows
    |> Enum.map(&on_runner(&1, filters["runner"]))
    |> Enum.filter(fn row ->
      matches?(filters["namespace"], to_string(row.namespace)) and
        matches?(filters["health"], to_string(row.health)) and
        matches?(filters["run"], to_string(row.run)) and
        if(row[:partitions],
          do: row.members != [],
          else: matches?(filters["runner"], to_string(row[:runner]))
        )
    end)
  end

  # A group spans runners, so asked about one it keeps the partitions there.
  defp on_runner(%{partitions: _, members: members} = group, runner) when runner not in [nil, ""],
    do: %{group | members: Enum.filter(members, &(to_string(&1[:runner]) == runner))}

  defp on_runner(row, _runner), do: row

  defp matches?(value, _actual) when value in [nil, ""], do: true
  defp matches?(value, actual), do: value == actual

  @doc "The rows drawn under `row`: a group's partitions while it is open."
  def open_members(row, expanded) do
    if row[:partitions] && MapSet.member?(expanded, group_key(row)),
      do: row.members,
      else: []
  end

  @doc "How an open group is remembered."
  def group_key(row), do: "#{row.namespace}/#{row.id}"

  @doc "A row's measured rate; a group's is its partitions' summed."
  def rate_of(%{partitions: _, members: members}, state),
    do: members |> Enum.map(&Map.get(state.rates, to_string(&1.id))) |> Topology.sum_rates()

  def rate_of(row, state), do: Map.get(state.rates, to_string(row.id))

  @doc "A row's rate history, oldest first; a group's sums its partitions' tick by tick."
  def history_of(%{partitions: _, members: members}, state) do
    members
    |> Enum.map(&Map.get(state.history, to_string(&1.id), []))
    |> Topology.sum_history()
  end

  def history_of(row, state),
    do: state.history |> Map.get(to_string(row.id), []) |> Enum.reverse()

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
    <span class="fui-rate-cell" data-testid={"relay-rate-#{@id}"}>
      <span class="fui-rate-spark">
        <.sparkline samples={@history} key={:in} width={56} height={16} testid={"relay-spark-#{@id}"} />
      </span>
      <span class="fui-rate-figures">
        <span class="fui-rate">{(@rate && Topology.rate_label(@rate.in)) || "—"}</span>
        <span :if={@rate[:bytes_in]} class="fui-figures">
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

  # The runs offered as filters are those present in the unfiltered listing,
  # so choosing one cannot make the others disappear from the choice.
  defp run_options(rows),
    do: rows |> Enum.map(& &1.run) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
end
