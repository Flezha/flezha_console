defmodule FlezhaUiWeb.NamespaceLive.Show do
  use FlezhaUiWeb, :live_view

  # The data-plane summary reads its rates from snapshot deltas, so this
  # screen ticks at the rate those deltas are worth measuring over. A runner
  # flip is the one state change worth showing before the next tick.
  use FlezhaUiWeb.Live.Refresh,
    every: 2_000,
    on_events: [:runner_connected, :runner_disconnected]

  use FlezhaUiWeb.Topology

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Topology

  @impl true
  def mount(%{"ns" => ns}, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> Topology.init()
      |> assign(
        ns: ns,
        page_title: ns,
        show_start_modal: false,
        start_form: %{
          "id" => "",
          "factory_id" => "",
          "init_values" => "",
          "snapshot_interval" => ""
        },
        start_error: nil,
        confirm_stop: nil,
        load_error: nil
      )
      |> refresh()

    {:ok, socket}
  end

  @impl true
  def handle_event("open_start_modal", _params, socket) do
    {:noreply, assign(socket, show_start_modal: true, start_error: nil)}
  end

  @impl true
  def handle_event("close_start_modal", _params, socket) do
    {:noreply, assign(socket, show_start_modal: false)}
  end

  @impl true
  def handle_event("start_form_change", %{"start" => params}, socket) do
    {:noreply, assign(socket, start_form: params)}
  end

  @impl true
  def handle_event("start_operative", %{"start" => params}, socket) do
    ns = socket.assigns.ns
    id = String.trim(params["id"])
    factory_id = String.trim(params["factory_id"])
    init_values_raw = String.trim(params["init_values"])

    with true <- id != "" and factory_id != "",
         {:ok, init_values} <- parse_json_or_empty(init_values_raw),
         opts <- build_opts(params) do
      case NodeManager.start_operative(ns, id, factory_id, init_values, opts) do
        {:ok, _result} ->
          socket =
            socket
            |> assign(show_start_modal: false, start_error: nil)
            |> refresh()
            |> put_flash(:info, "Operative #{id} started.")

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, start_error: inspect(reason))}
      end
    else
      false ->
        {:noreply, assign(socket, start_error: "ID and Factory ID are required.")}

      {:error, _} ->
        {:noreply, assign(socket, start_error: "Init Values must be valid JSON.")}
    end
  end

  @impl true
  def handle_event("confirm_stop", %{"operative_id" => operative_id}, socket) do
    {:noreply, assign(socket, confirm_stop: operative_id)}
  end

  @impl true
  def handle_event("cancel_stop", _params, socket) do
    {:noreply, assign(socket, confirm_stop: nil)}
  end

  @impl true
  def handle_event("stop_operative", %{"operative_id" => operative_id}, socket) do
    ns = socket.assigns.ns

    case NodeManager.stop_operative(ns, operative_id) do
      :ok ->
        socket =
          socket
          |> assign(confirm_stop: nil)
          |> refresh()
          |> put_flash(:info, "Operative #{operative_id} stopped.")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(confirm_stop: nil)
          |> put_flash(:error, "Failed to stop: #{inspect(reason)}")

        {:noreply, socket}
    end
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    ns = socket.assigns.ns

    {operative_ids, load_error} =
      case NodeManager.list_operatives(ns) do
        {:ok, list} -> {list, nil}
        {:error, reason} -> {[], reason}
      end

    operatives =
      Enum.map(operative_ids, fn operative_id ->
        facts =
          ns
          |> NodeManager.overwatch_facts(operative_id)
          |> NodeManager.ok_or(NodeManager.overwatch_facts())

        %{id: operative_id, runner_id: facts.runner_id}
      end)

    socket
    |> assign(
      operatives: operatives,
      runners: NodeManager.ok_or(NodeManager.list_runners(ns), []),
      factories: NodeManager.ok_or(NodeManager.list_factories(ns), []),
      load_error: load_error
    )
    |> Topology.load_summary(ns)
  end

  defp parse_json_or_empty(""), do: {:ok, %{}}
  defp parse_json_or_empty(str), do: Jason.decode(str)

  defp build_opts(params) do
    case params["snapshot_interval"] do
      "" ->
        []

      nil ->
        []

      val ->
        case Integer.parse(val) do
          {n, ""} -> [snapshot_interval: n]
          _ -> []
        end
    end
  end
end
