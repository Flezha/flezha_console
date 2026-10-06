defmodule FlezhaUiWeb.NamespaceLive.Show do
  use FlezhaUiWeb, :live_view

  # The data-plane summary reads its rates from snapshot deltas, so this
  # screen ticks at the rate those deltas are worth measuring over. A runner
  # flip is the one state change worth showing before the next tick.
  use FlezhaUiWeb.Live.Refresh,
    every: 2_000,
    on_events: [:runner_connected, :runner_disconnected]

  use FlezhaUiWeb.Topology
  use FlezhaUiWeb.Live.Launcher

  # The namespace's own relays are what the screen is for; everything that
  # administers the namespace is folded away until asked for. A breached quota
  # overrides that — see the `forced` section in the template.
  use FlezhaUiWeb.Live.Sections,
    open: %{
      "quotas" => false,
      "role-bindings" => false,
      "partition-groups" => false,
      "finished-relays" => false,
      "runners" => false
    }

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Topology

  @impl true
  def mount(%{"ns" => ns}, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> Topology.init()
      |> launcher_init(ns)
      |> sections_init()
      |> assign(
        ns: ns,
        page_title: ns,
        confirm_stop: nil,
        load_error: nil,
        finished: [],
        finished_error: nil,
        finished_loading?: false,
        rescale: nil,
        quota_form: nil,
        quota_error: nil
      )
      |> refresh()
      |> load_finished()

    {:ok, socket}
  end

  # Four dialogs and the launcher, any of which a row could move underneath.
  @impl FlezhaUiWeb.Live.Refresh
  def refresh_paused?(socket) do
    FlezhaUiWeb.Live.Launcher.open?(socket) or socket.assigns.confirm_stop != nil or
      socket.assigns.rescale != nil or socket.assigns.quota_form != nil
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
    limits = quota_limits(socket.assigns.quota_form, socket.assigns.declared)

    case NodeManager.set_namespace_quotas(socket.assigns.ns, limits, socket.assigns.flezha_token) do
      {:error, reason} ->
        {:noreply, assign(socket, quota_error: reason)}

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

    case NodeManager.rescale(ns, group, target, socket.assigns.flezha_token) do
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(rescale: nil)
         |> put_flash(:error, FlezhaUiWeb.CoreComponents.error_message(reason, "the rescale"))}

      _ok ->
        {:noreply,
         socket
         |> assign(rescale: nil)
         |> refresh()
         |> put_flash(:info, "Rescaling #{group} to #{target} members.")}
    end
  end

  @impl true
  def handle_event("confirm_stop", %{"relay_id" => relay_id}, socket) do
    {:noreply, assign(socket, confirm_stop: relay_id)}
  end

  @impl true
  def handle_event("cancel_stop", _params, socket) do
    {:noreply, assign(socket, confirm_stop: nil)}
  end

  @impl true
  def handle_event("stop_relay", %{"relay_id" => relay_id}, socket) do
    case NodeManager.stop_relay(socket.assigns.ns, relay_id, socket.assigns.flezha_token) do
      {:ok, answer} ->
        {:noreply,
         socket
         |> assign(confirm_stop: nil)
         |> refresh()
         |> put_flash(:info, stopped_message(relay_id, answer))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_stop: nil)
         |> put_flash(:error, FlezhaUiWeb.CoreComponents.error_message(reason, "the stop"))}
    end
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    %{ns: ns, flezha_token: token} = socket.assigns

    # One listing read answers every row's health, node, factory, runner and
    # partition group, collapsed by the controller's own rule; the member rows
    # behind them feed the group panel and the summary.
    {relays, load_error} = NodeManager.ok_or_error(NodeManager.relay_list(ns, token), [])
    rows = ns |> NodeManager.relay_rows(token) |> NodeManager.ok_or([])
    groups = rows |> NodeManager.partition_groups(token) |> with_group_health(relays)

    plugin_counts =
      ns
      |> NodeManager.relay_plugins(token)
      |> NodeManager.ok_or([])
      |> NodeManager.plugin_counts()

    declared = NodeManager.ok_or(NodeManager.namespace_record(ns, token), nil)
    quotas = NodeManager.quota_usage(ns, declared && declared.quotas, token)

    socket
    |> assign(
      relays: relays,
      runs: ns |> NodeManager.relay_runs(token) |> NodeManager.ok_or(%{}),
      plugin_counts: plugin_counts,
      groups: groups,
      runners: ns |> NodeManager.runners(token) |> NodeManager.ok_or([]),
      declared: declared,
      quotas: quotas,
      # A breach is never hidden behind a click, so it outranks the screen's
      # own collapse default and whatever the viewer last chose.
      quota_breached: Enum.any?(quotas, & &1.breached?),
      role_bindings: ns |> NodeManager.roles(token) |> NodeManager.ok_or([]),
      load_error: load_error
    )
    |> Topology.load_summary(ns, %{rows: rows, groups: groups})
  end

  # A group is as healthy as its sickest member, and `Relay.list/2` already
  # answers its row ranked that way, so the panel takes it from there rather
  # than ranking the members a second time.
  defp with_group_health(groups, relays) do
    health = Map.new(relays, &{to_string(&1.id), &1.health})
    Enum.map(groups, &Map.put(&1, :health, Map.get(health, to_string(&1.id), :unknown)))
  end

  # The controller replaces a namespace's overrides whole, so every limit the
  # record holds is sent, with the ones the operator typed written over it. A
  # field left blank keeps the limit it had.
  defp quota_limits(form, declared) do
    held = (declared && declared.quotas) || %{}

    Enum.reduce(form, held, fn {key, typed}, acc ->
      case Integer.parse(String.trim(typed || "")) do
        {value, ""} when value >= 0 -> put_limit(acc, key, value)
        _blank_or_invalid -> acc
      end
    end)
  end

  defp put_limit(limits, key, value) do
    case Enum.find(Map.keys(limits), &(to_string(&1) == key)) do
      nil -> limits
      atom -> Map.put(limits, atom, value)
    end
  end

  defp stopped_message(id, %{stopped: :cooperative}),
    do: "Relay #{id} is stopping: it finishes its in-flight work before it is removed."

  defp stopped_message(id, _answer), do: "Relay #{id} stopped."

  # Off the refresh tick and off the mount: the controller reads an overwatch
  # per live relay to answer it, which is seconds on a busy namespace. Loaded
  # once the screen is connected, and again when an operator asks for it.
  # A read already in flight is left to finish: starting another would cancel
  # it, and an operator clicking Reload twice would then never see an answer.
  defp load_finished(%{assigns: %{finished_loading?: true}} = socket), do: socket

  defp load_finished(socket) do
    if connected?(socket) do
      %{ns: ns, flezha_token: token} = socket.assigns

      socket
      |> assign(finished_loading?: true)
      |> start_async(:finished, fn -> NodeManager.finished_relays(ns, token) end)
    else
      socket
    end
  end

  @impl true
  def handle_async(:finished, result, socket) do
    socket = assign(socket, finished_loading?: false)

    case result do
      {:ok, {:ok, finished}} ->
        {:noreply, assign(socket, finished: finished, finished_error: nil)}

      {:ok, {:error, reason}} ->
        {:noreply, assign(socket, finished: [], finished_error: reason)}

      {:exit, reason} ->
        {:noreply, assign(socket, finished: [], finished_error: {:remote_error, reason})}
    end
  end
end
