defmodule FlezhaUiWeb.NamespaceLive.Show do
  use FlezhaUiWeb, :live_view

  alias FlezhaUi.Service.NodeManager

  @refresh_interval 5_000

  @impl true
  def mount(%{"ns" => ns}, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)

    socket =
      socket
      |> assign(
        ns: ns,
        page_title: ns,
        show_start_modal: false,
        start_form: %{"id" => "", "factory_id" => "", "init_values" => "", "snapshot_interval" => ""},
        start_error: nil,
        confirm_stop: nil
      )
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, load_data(socket)}
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
  def handle_event("start_processor", %{"start" => params}, socket) do
    ns = socket.assigns.ns
    id = String.trim(params["id"])
    factory_id = String.trim(params["factory_id"])
    init_values_raw = String.trim(params["init_values"])

    with true <- id != "" and factory_id != "",
         {:ok, init_values} <- parse_json_or_empty(init_values_raw),
         opts <- build_opts(params) do
      case NodeManager.start_processor(ns, id, factory_id, init_values, opts) do
        {:ok, _result} ->
          socket =
            socket
            |> assign(show_start_modal: false, start_error: nil)
            |> load_data()
            |> put_flash(:info, "Processor #{id} started.")

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
  def handle_event("confirm_stop", %{"processor_id" => proc_id}, socket) do
    {:noreply, assign(socket, confirm_stop: proc_id)}
  end

  @impl true
  def handle_event("cancel_stop", _params, socket) do
    {:noreply, assign(socket, confirm_stop: nil)}
  end

  @impl true
  def handle_event("stop_processor", %{"processor_id" => proc_id}, socket) do
    ns = socket.assigns.ns

    case NodeManager.stop_processor(ns, proc_id) do
      :ok ->
        socket =
          socket
          |> assign(confirm_stop: nil)
          |> load_data()
          |> put_flash(:info, "Processor #{proc_id} stopped.")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(confirm_stop: nil)
          |> put_flash(:error, "Failed to stop: #{inspect(reason)}")

        {:noreply, socket}
    end
  end

  defp load_data(socket) do
    ns = socket.assigns.ns

    processors =
      case NodeManager.list_processors(ns) do
        {:ok, list} ->
          Enum.map(list, fn proc_id ->
            ce_id =
              case NodeManager.get_overwatch_state(ns, proc_id) do
                {:ok, state} -> Map.get(state, :compute_engine_id) || Map.get(state, "compute_engine_id")
                _ -> nil
              end

            %{id: proc_id, compute_engine_id: ce_id}
          end)

        _ ->
          []
      end

    compute_engines =
      case NodeManager.list_compute_engines(ns) do
        {:ok, list} -> list
        _ -> []
      end

    assign(socket, processors: processors, compute_engines: compute_engines)
  end

  defp parse_json_or_empty(""), do: {:ok, %{}}
  defp parse_json_or_empty(str), do: Jason.decode(str)

  defp build_opts(params) do
    case params["snapshot_interval"] do
      "" -> []
      nil -> []
      val ->
        case Integer.parse(val) do
          {n, ""} -> [snapshot_interval: n]
          _ -> []
        end
    end
  end
end
