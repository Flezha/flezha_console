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
        load_error: nil,
        finished: [],
        finished_error: nil,
        rescale: nil,
        quota_form: nil,
        quota_error: nil
      )
      |> refresh()
      |> load_finished()

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
  def handle_event("open_quotas", _params, socket) do
    form =
      Map.new(socket.assigns.quotas, fn row ->
        {to_string(row.limit_key), if(row.limit, do: to_string(row.limit), else: "")}
      end)

    {:noreply, assign(socket, quota_form: form, quota_error: nil)}
  end

  @impl true
  def handle_event("close_quotas", _params, socket) do
    {:noreply, assign(socket, quota_form: nil)}
  end

  @impl true
  def handle_event("quota_change", %{"quota" => params}, socket) do
    {:noreply, assign(socket, quota_form: Map.merge(socket.assigns.quota_form, params))}
  end

  @impl true
  def handle_event("save_quotas", _params, socket) do
    changed = changed_quotas(socket.assigns.quota_form, socket.assigns.quotas)

    case NodeManager.set_namespace_quotas(socket.assigns.ns, changed) do
      {:error, reason} ->
        {:noreply, assign(socket, quota_error: inspect(reason))}

      _ok ->
        {:noreply,
         socket
         |> assign(quota_form: nil, quota_error: nil)
         |> refresh()
         |> put_flash(:info, "Quotas updated.")}
    end
  end

  @impl true
  def handle_event("reload_finished", _params, socket) do
    {:noreply, load_finished(socket)}
  end

  @impl true
  def handle_event("open_rescale", %{"group" => group}, socket) do
    members =
      socket.assigns.groups
      |> Enum.find(%{}, &(to_string(&1.id) == group))
      |> Map.get(:members, [])

    {:noreply, assign(socket, rescale: %{group: group, target: length(members)})}
  end

  @impl true
  def handle_event("cancel_rescale", _params, socket) do
    {:noreply, assign(socket, rescale: nil)}
  end

  @impl true
  def handle_event("select_rescale", %{"rescale" => %{"target" => value}}, socket) do
    case Integer.parse(to_string(value)) do
      {target, ""} when target >= 1 ->
        {:noreply, assign(socket, rescale: %{socket.assigns.rescale | target: target})}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("rescale", _params, socket) do
    %{ns: ns, rescale: %{group: group, target: target}} = socket.assigns

    case NodeManager.rescale_group(ns, group, target) do
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(rescale: nil)
         |> put_flash(:error, "Rescale failed: #{inspect(reason)}")}

      _ok ->
        {:noreply,
         socket
         |> assign(rescale: nil)
         |> refresh()
         |> put_flash(:info, "Rescaling #{group} to #{target} members.")}
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

    # One registry dump answers every row's health, node, factory, runner and
    # partition identity. The listing this replaced cost an overwatch call per
    # operative and still could not say whether any of them were healthy.
    {rows, load_error} = NodeManager.ok_or_error(NodeManager.operative_rows(ns), [])

    plugin_counts =
      ns
      |> NodeManager.operative_plugins()
      |> NodeManager.ok_or([])
      |> NodeManager.plugin_counts()

    decorated = NodeManager.decorate_health(rows)
    groups = NodeManager.partition_groups(decorated)

    declared = NodeManager.ok_or(NodeManager.declared_namespace(ns), nil)

    socket
    |> assign(
      operatives: decorated,
      plugin_counts: plugin_counts,
      groups: groups,
      runners: NodeManager.ok_or(NodeManager.list_runners(ns), []),
      factories: NodeManager.ok_or(NodeManager.list_factories(ns), []),
      declared: declared,
      quotas: NodeManager.quota_usage(ns, declared && declared.quotas),
      role_bindings: NodeManager.ok_or(NodeManager.role_bindings(ns), []),
      load_error: load_error
    )
    |> Topology.load_summary(ns, %{rows: decorated, groups: groups})
  end

  # Only the kinds whose value actually moved are sent, so a save does not
  # rewrite limits the operator never touched.
  defp changed_quotas(form, quotas) do
    Enum.reduce(quotas, %{}, fn row, acc ->
      typed = String.trim(Map.get(form, to_string(row.limit_key), ""))

      case Integer.parse(typed) do
        {value, ""} when value != :error ->
          if value == row.limit, do: acc, else: Map.put(acc, row.limit_key, value)

        _ ->
          acc
      end
    end)
  end

  # Deliberately off the refresh tick: there is no bulk completion read on the
  # controller, so this costs one call per persisted class that is not live.
  # Loaded on arrival and when an operator asks for it again.
  defp load_finished(socket) do
    live = Enum.map(socket.assigns.operatives, & &1.id)

    case NodeManager.finished_instances(socket.assigns.ns, live) do
      {:ok, finished} -> assign(socket, finished: finished, finished_error: nil)
      {:error, reason} -> assign(socket, finished: [], finished_error: reason)
    end
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
