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
     )
     |> refresh()}
  end

  # The start form offers the namespaces this screen already listed, so asking
  # where to start costs no second read.
  @impl FlezhaUiWeb.Live.Launcher
  def launcher_namespaces(socket), do: {socket.assigns.namespaces, socket.assigns.load_error}

  # Filters live in the query string as well as the form, so the fleet
  # summary's health buckets can link straight to the operatives they counted.
  @impl true
  def handle_params(params, _uri, socket) do
    filters =
      Enum.reduce(~w(namespace health kind), socket.assigns.filters, fn key, acc ->
        case Map.get(params, key) do
          value when is_binary(value) -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    {:noreply, socket |> assign(filters: filters) |> refresh()}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = Map.merge(socket.assigns.filters, params)

    {:noreply, socket |> assign(filters: filters) |> refresh()}
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token

    {namespaces, load_error} = NodeManager.scoped_namespaces(token)

    rows = Enum.flat_map(namespaces, &namespace_rows/1)

    assign(socket,
      namespaces: Enum.sort(namespaces),
      rows: filter(rows, socket.assigns.filters),
      load_error: load_error
    )
  end

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
  The health values offered as filters, so the list cannot drift from the badge.

  `:suspended` is one of them: the Convergence Loop ranks suspension in the
  health ladder, so filtering to suspended instances is a health filter and
  costs nothing beyond the listing's own read.
  """
  def health_options, do: NodeManager.health_kinds()
end
