defmodule FlezhaConsoleWeb.NamespaceLive.Index do
  @moduledoc """
  Namespaces as objects, not merely as running hubs.

  The controller's catalog answers every namespace the caller may see with
  whether a hub runs for it, so a namespace declared with nothing running is
  listed too, and each row says which it is. The declarations — quotas and who
  created them — are read beside it.
  """

  use FlezhaConsoleWeb, :live_view

  use FlezhaConsoleWeb.Live.Refresh, every: 5_000

  alias FlezhaConsole.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> assign(
       page_title: "Namespaces",
       namespaces: [],
       unreachable: [],
       load_error: nil,
       declarations_unavailable?: false,
       show_create: false,
       create_form: %{"name" => "", "max_relays" => "", "max_runners" => ""},
       create_error: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_event("open_create", _params, socket) do
    {:noreply, assign(socket, show_create: true, create_error: nil)}
  end

  @impl true
  def handle_event("close_create", _params, socket) do
    {:noreply, assign(socket, show_create: false)}
  end

  @impl true
  def handle_event("create_change", %{"create" => params}, socket) do
    {:noreply, assign(socket, create_form: Map.merge(socket.assigns.create_form, params))}
  end

  @impl true
  def handle_event("create", %{"create" => params}, socket) do
    name = String.trim(params["name"] || "")

    with :ok <- if(name == "", do: {:error, "A namespace name is required."}, else: :ok),
         {:ok, limits} <- NodeManager.parse_limits(params, ~w(max_relays max_runners)a),
         {:ok, _entry} <- NodeManager.create_namespace(name, limits, socket.assigns.flezha_token) do
      {:noreply,
       socket
       |> assign(show_create: false, create_error: nil)
       |> refresh()
       |> put_flash(:info, "Namespace #{name} declared.")}
    else
      {:error, reason} -> {:noreply, assign(socket, create_error: reason)}
    end
  end

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token

    case NodeManager.list_namespaces(token) do
      {:ok, %{rows: catalog}} = listed ->
        {records, unavailable?} = records(token)
        namespaces = Enum.map(catalog, &row(&1, records, token))

        assign(socket,
          namespaces: namespaces,
          declarations_unavailable?: unavailable?,
          unreachable:
            NodeManager.unreachable([listed | Enum.flat_map(namespaces, & &1.answers)]),
          load_error: nil
        )

      {:error, reason} ->
        assign(socket,
          namespaces: [],
          declarations_unavailable?: false,
          unreachable: [],
          load_error: reason
        )
    end
  end

  # A controller that cannot answer the records still lists its namespaces,
  # and the screen says the declarations are what is missing.
  defp records(token) do
    case NodeManager.namespace_records(token) do
      {:ok, records} -> {Map.new(records, &{to_string(&1.name), &1}), false}
      {:error, _reason} -> {%{}, true}
    end
  end

  # `running` is a hub running on any controller.
  defp row(%{namespace: name, running: running?}, records, token) do
    name = to_string(name)
    record = Map.get(records, name)

    # A namespace with no hub has nothing running in it, which is zero rather
    # than unknown. One registry read gives both the count and the health.
    read_rows = if running?, do: NodeManager.relay_rows(name, token), else: {:ok, []}
    rows = NodeManager.ok_or(read_rows, [])
    usage = quota_usage(name, record, token)

    %{
      name: name,
      declared?: record != nil,
      running?: running?,
      quotas: record && record.quotas,
      relay_count: length(rows),
      health: NodeManager.health_counts(rows),
      runner_count: if(running?, do: count(NodeManager.runners(name, token)), else: 0),
      breaches: Enum.filter(usage, & &1.breached?),
      answers: [read_rows | usage]
    }
  end

  # Only a declared namespace has limits to breach; an undeclared one has
  # counters but nothing to measure them against.
  defp quota_usage(_name, nil, _token), do: []
  defp quota_usage(name, record, token), do: NodeManager.quota_usage(name, record.quotas, token)

  defp count(result), do: result |> NodeManager.ok_or([]) |> length()
end
