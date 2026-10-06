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
  as they happen; each one reloads the rows and is kept, newest first, in a
  bounded lifecycle list narrowed to the namespaces the token reaches.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh,
    every: 5_000,
    on_events: [:runner_connected, :runner_disconnected]

  use FlezhaUiWeb.Live.Launcher

  alias FlezhaUi.Service.EventFeed
  alias FlezhaUi.Service.NodeManager

  @lifecycle_events [:relay_started, :relay_stopped, :relay_exited]
  @lifecycle_max 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> launcher_init(nil)
     |> assign(
       page_title: "Relays",
       filters: %{"namespace" => "", "health" => "", "run" => ""},
       rows: [],
       run_options: [],
       namespaces: [],
       load_error: nil,
       lifecycle: [],
       lifecycle_error: subscribe_lifecycle(socket)
     )}
  end

  # Subscribes to the relay lifecycle feed and answers why it is refused, if it
  # is. Only once connected: the dead render has no feed to hear from.
  defp subscribe_lifecycle(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic(:flezha_relay))
      EventFeed.error(EventFeed.signal_feed(:flezha_relay))
    end
  end

  @impl true
  def handle_info({:flezha_event, event, {namespace, entry}}, socket)
      when event in @lifecycle_events do
    if shown?(socket, namespace) do
      socket = update(socket, :lifecycle, &Enum.take([entry | &1], @lifecycle_max))
      {:noreply, FlezhaUiWeb.Live.Refresh.tick(__MODULE__, socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:flezha_feed, _feed, error}, socket),
    do: {:noreply, assign(socket, lifecycle_error: error)}

  # A signal is shown only for a namespace the token reaches, and on a scoped
  # screen only for its own.
  defp shown?(socket, namespace) do
    namespace = to_string(namespace)

    namespace in socket.assigns.namespaces and
      socket.assigns.scoped_namespace in [nil, namespace]
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
      ~w(namespace health run)
      |> Map.new(fn key -> {key, to_string(params[key] || "")} end)
      |> then(&if(scope, do: Map.put(&1, "namespace", scope), else: &1))

    socket =
      socket
      |> assign(
        filters: filters,
        page_title: Layouts.scoped_title(screen_name(scope), scope)
      )
      |> refresh()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = Map.merge(socket.assigns.filters, params)

    {:noreply, push_patch(socket, to: filtered_path(socket.assigns.scoped_namespace, filters))}
  end

  # A blank filter is left out entirely, and a scoped screen's namespace is
  # already a path segment — repeating it in the query string would give the
  # same scope two places to disagree from.
  defp filtered_path(scope, filters) do
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

    assign(socket,
      namespaces: Enum.sort(namespaces),
      rows: filter(rows, socket.assigns.filters),
      run_options: run_options(rows),
      load_error: load_error
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

    namespace
    |> NodeManager.relay_list(token)
    |> NodeManager.ok_or([])
    |> Enum.map(fn row ->
      id = to_string(row.id)

      row
      |> Map.put(:namespace, namespace)
      |> Map.put(:run, run_of(row, runs))
      |> Map.put(:plugins, Map.get(plugins, id, 0))
    end)
  end

  # A group row is no registry entry of its own; its run is its members'.
  defp run_of(%{members: [member | _]}, runs), do: Map.get(runs, to_string(member.id))
  defp run_of(row, runs), do: Map.get(runs, to_string(row.id))

  defp filter(rows, filters) do
    Enum.filter(rows, fn row ->
      matches?(filters["namespace"], to_string(row.namespace)) and
        matches?(filters["health"], to_string(row.health)) and
        matches?(filters["run"], to_string(row.run))
    end)
  end

  defp matches?(value, _actual) when value in [nil, ""], do: true
  defp matches?(value, actual), do: value == actual

  @doc "What a lifecycle entry says happened."
  def lifecycle_text(%{event: :relay_started} = entry),
    do: "started from #{entry.factory || "an unnamed factory"}"

  def lifecycle_text(%{event: :relay_stopped} = entry), do: "stopped: #{reason(entry.reason)}"

  def lifecycle_text(%{event: :relay_exited} = entry),
    do: "exited on runner #{entry.runner || "—"}: #{reason(entry.reason)}"

  defp reason(nil), do: "no reason given"
  defp reason(reason), do: Format.printable(reason)

  @doc """
  What this screen is called at the scope it is showing.

  Unscoped it is the whole Fleet; scoped it is that namespace's Relays —
  said here so the heading and the page title cannot disagree about it.
  """
  def screen_name(nil), do: "Fleet"
  def screen_name(_scope), do: "Relays"

  @doc """
  The health values offered as filters, so the list cannot drift from the badge.

  Every verdict the controller answers is one of them, `recovering` and
  `parked` included. `:suspended` too: the Convergence Loop ranks suspension in
  the health ladder, so filtering to suspended relays is a health filter and
  costs nothing beyond the listing's own read.
  """
  def health_options, do: NodeManager.health_verdicts()

  # The runs offered as filters are those present in the unfiltered listing,
  # so choosing one cannot make the others disappear from the choice.
  defp run_options(rows),
    do: rows |> Enum.map(& &1.run) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
end
