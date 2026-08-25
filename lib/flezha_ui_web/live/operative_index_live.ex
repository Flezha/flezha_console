defmodule FlezhaUiWeb.OperativeIndexLive do
  @moduledoc """
  Every operative the bound token can reach, across every namespace.

  "Where is everything, and what is unhealthy?" is a different question from
  "what is in this namespace", and it is the one an operator asks first when
  something is wrong. It is affordable because the per-namespace read is flat:
  one rows call, one plugins call and one kinds call per namespace, never a
  call per operative.

  It also carries the start form, so an operator reading "everything, anywhere"
  can act on it without first working out which namespace to navigate into. The
  form's factory catalog is read when it opens, so the listing itself stays
  flat.

  The same screen serves one namespace at `/namespaces/:ns/operatives`. It is
  the same listing with the namespace filter already applied — taken from the
  path rather than from the form, so the address bar names the scope and the
  screen renders it as fixed rather than as something to clear.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh,
    every: 5_000,
    on_events: [:runner_connected, :runner_disconnected]

  use FlezhaUiWeb.Live.Launcher

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> launcher_init(nil)
     |> assign(
       page_title: "Operatives",
       filters: %{"namespace" => "", "health" => "", "kind" => ""},
       rows: [],
       namespaces: [],
       load_error: nil
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
      ~w(namespace health kind)
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
      do: ~p"/namespaces/#{scope}/operatives?#{query}",
      else: ~p"/operatives?#{query}"
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
      |> Enum.flat_map(&namespace_rows/1)

    assign(socket,
      namespaces: Enum.sort(namespaces),
      rows: filter(rows, socket.assigns.filters),
      load_error: load_error
    )
  end

  defp listed(namespaces, nil), do: namespaces
  defp listed(namespaces, scope), do: if(scope in namespaces, do: [scope], else: [])

  defp namespace_rows(namespace) do
    plugins =
      namespace
      |> NodeManager.operative_plugins()
      |> NodeManager.ok_or([])
      |> NodeManager.plugin_counts()

    kinds = namespace |> NodeManager.operative_kinds() |> NodeManager.ok_or(%{})

    namespace
    |> NodeManager.namespace_rows()
    |> Enum.map(fn row ->
      id = to_string(row.id)

      row
      |> Map.put(:namespace, namespace)
      |> Map.put(:kind, Map.get(kinds, id, :stream))
      |> Map.put(:plugins, Map.get(plugins, id, 0))
    end)
  end

  defp filter(rows, filters) do
    Enum.filter(rows, fn row ->
      matches?(filters["namespace"], to_string(row.namespace)) and
        matches?(filters["health"], to_string(row.health)) and
        matches?(filters["kind"], to_string(row.kind))
    end)
  end

  defp matches?(value, _actual) when value in [nil, ""], do: true
  defp matches?(value, actual), do: value == actual

  @doc """
  What this screen is called at the scope it is showing.

  Unscoped it is the whole Fleet; scoped it is that namespace's Operatives —
  said here so the heading and the page title cannot disagree about it.
  """
  def screen_name(nil), do: "Fleet"
  def screen_name(_scope), do: "Operatives"

  @doc """
  The health values offered as filters, so the list cannot drift from the badge.

  `:suspended` is one of them: the Convergence Loop ranks suspension in the
  health ladder, so filtering to suspended instances is a health filter and
  costs nothing beyond the listing's own read.
  """
  def health_options, do: NodeManager.health_kinds()
end
