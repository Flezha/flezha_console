defmodule FlezhaConsoleWeb.NamespaceLive.Show do
  @moduledoc """
  A namespace's Dashboard: a headline sentence, the namespace's open problems,
  indicator tiles for the namespace, the event river, and its administration
  folded below — limits, access, partition groups, recent runs and runners.

  It replaces both the former dashboard and the namespace overview, and is the
  only screen that renders the namespace's data-plane summary. Figures for
  everything the operator reaches are the Cluster screen's.
  """

  use FlezhaConsoleWeb, :live_view

  # The flow figures are snapshot deltas, so this screen ticks at the rate
  # those deltas are worth measuring over. A runner flip is the one state
  # change worth showing before the next tick.
  use FlezhaConsoleWeb.Live.Refresh,
    every: 2_000,
    on_events: [:runner_connected, :runner_disconnected, :runner_dropped, :runner_readmitted],
    background: true

  use FlezhaConsoleWeb.Topology
  use FlezhaConsoleWeb.Live.Launcher
  use FlezhaConsoleWeb.Live.RunnerActions
  use FlezhaConsoleWeb.Attention
  use FlezhaConsoleWeb.River
  use FlezhaConsoleWeb.Inspect, kinds: ~w(relay runner plugin)

  # The namespace's data plane is what the screen is for; everything that
  # administers the namespace is folded away until asked for. A breached quota
  # overrides that — see the `forced` section in the template.
  use FlezhaConsoleWeb.Live.Sections,
    open: %{
      "quotas" => false,
      "access" => false,
      "partition-groups" => false,
      "recent-runs" => false,
      "runners" => false
    }

  alias FlezhaConsole.Format
  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.Attention
  alias FlezhaConsoleWeb.Live.Sections
  alias FlezhaConsoleWeb.Topology

  @impl true
  def mount(%{"ns" => ns}, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> Topology.init()
      |> launcher_init(ns)
      |> runner_actions_init()
      |> sections_init()
      |> attention_init()
      |> river_init()
      |> assign(
        ns: ns,
        page_title: ns,
        loaded?: false,
        params: %{},
        confirm_stop: nil,
        load_error: nil,
        plugins: %{total: 0, names: []},
        schedules: [],
        groups: :unread,
        broken_groups: 0,
        runners: [],
        runner_marks: [],
        declared: nil,
        quotas: [],
        quota_breached: false,
        role_bindings: [],
        items: [],
        health: [],
        relay_count: 0,
        unreachable: [],
        runs: [],
        runs_next: nil,
        runs_error: nil,
        runs_grown?: false,
        runs_loading?: false,
        rescale: nil,
        quota_form: nil,
        quota_error: nil,
        tokens: [],
        tokens_error: nil,
        token_status: "active",
        factory_descriptions: nil
      )
      |> refresh_when_connected()
      |> on_older_runs()

    {:ok, socket}
  end

  # The inspector answers from the rows the screen holds, so an address naming
  # a selection is applied once the first read has landed.
  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :params, params)

    if socket.assigns.loaded?,
      do: {:noreply, inspect_params(socket, params)},
      else: {:noreply, inspect_params(socket, Map.delete(params, "inspect"))}
  end

  # The dialogs and the launcher, any of which a row could move underneath.
  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_paused?(socket) do
    FlezhaConsoleWeb.Live.Launcher.open?(socket) or
      Enum.any?(
        ~w(confirm_stop rescale quota_form)a,
        &(socket.assigns[&1] != nil)
      )
  end

  # ---- Tokens ----

  @impl true
  def handle_event("token_status", %{"value" => status}, socket)
      when status in ~w(active revoked expired all),
      do: {:noreply, assign(socket, token_status: status)}

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
    # The controller replaces a namespace's overrides whole, so every limit the
    # record holds is sent, with the ones the operator typed written over it. A
    # field left blank keeps the limit it had.
    held = (socket.assigns.declared && socket.assigns.declared.quotas) || %{}

    case NodeManager.parse_limits(socket.assigns.quota_form, Map.keys(held)) do
      {:ok, typed} -> {:noreply, save_quotas(socket, Map.merge(held, typed))}
      {:error, message} -> {:noreply, assign(socket, quota_error: message)}
    end
  end

  @impl true
  def handle_event("open_rescale", %{"group" => group}, socket) do
    members =
      socket.assigns.groups
      |> List.wrap()
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
         |> put_flash(:error, error_message(reason, "the rescale"))}

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
         |> put_flash(:info, Format.relay_stopped(relay_id, answer))
         |> close_inspector(relay_id)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_stop: nil)
         |> put_flash(:error, error_message(reason, "the stop"))}
    end
  end

  # A stopped relay's inspector has nothing left to show.
  defp close_inspector(%{assigns: %{inspected: %{kind: "relay", relay: relay}}} = socket, relay),
    do: push_patch(socket, to: inspect_path(socket, nil))

  defp close_inspector(socket, _relay), do: socket

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_read(socket) do
    %{ns: ns, flezha_token: token, items: items, loaded?: loaded?} = socket.assigns
    previous = {items, socket.assigns[:serving]}

    asked = %{
      relays: Attention.relay_opts(Attention.shown(socket.assigns.paging, ns)),
      # Read on the first read, then only while someone looks at them.
      runs?: not loaded? or socket.assigns.sections["recent-runs"],
      groups?: socket.assigns.sections["partition-groups"] == true
    }

    fn ->
      runs = if asked.runs?, do: recent_runs(ns, token)
      ns |> read(token, previous, loaded?, asked) |> Map.put(:runs, runs)
    end
  end

  # Every call one Dashboard read makes, run off the screen's process. Once the
  # screen shows figures, a read whose relays failed stops there: its answer
  # keeps them, so the rest would only delay the error.
  defp read(ns, token, previous, loaded?, asked) do
    # The most severe relays and the namespace's summary: the tiles and the
    # problems are built from it, never from every relay's row.
    read_page = NodeManager.relay_list(ns, token, asked.relays)

    case NodeManager.ok_or_error(read_page, []) do
      {_rows, error} when error != nil and loaded? ->
        if NodeManager.connected_node(),
          do: %{load_error: error},
          else: read_with_page(ns, token, previous, read_page, asked)

      _rows ->
        read_with_page(ns, token, previous, read_page, asked)
    end
  end

  defp read_with_page(ns, token, previous, read_page, asked) do
    {_rows, load_error} = NodeManager.ok_or_error(read_page, [])
    page = Attention.page(read_page)
    declared = NodeManager.ok_or(NodeManager.namespace_record(ns, token), nil)
    quotas = NodeManager.quota_usage(ns, declared && declared.quotas, token)

    {connected_runners, runners_error} =
      ns |> NodeManager.runners(token) |> NodeManager.ok_or_error([])

    catalog = NodeManager.factory_catalog(ns, token)
    plugins = NodeManager.plugins(ns, token, limit: 2)
    schedules = NodeManager.schedule_list(token)

    runners =
      FlezhaConsoleWeb.Runners.rows(
        connected_runners,
        catalog |> NodeManager.ok_or([]) |> NodeManager.factories_by_runner()
      )

    {tokens, tokens_error} = tokens(ns, token)
    summary = Topology.read_summary(token, ns)

    %{
      assigns: [
        health: page.health,
        relay_count: page.relay_count,
        broken_groups: Enum.count(Map.get(page.summary, :faulted_groups, []), &(!&1.complete)),
        unreachable: NodeManager.unreachable([read_page, catalog, plugins, schedules | quotas]),
        plugins: plugin_figures(plugins),
        schedules:
          schedules
          |> NodeManager.ok_or([])
          |> FlezhaConsoleWeb.ScheduleLive.rows(ns),
        groups: if(asked.groups?, do: groups(ns, token, page), else: :unread),
        runners: runners,
        runners_read?: is_nil(runners_error),
        runner_marks: ns |> NodeManager.dropped_runners(token) |> NodeManager.ok_or([]),
        declared: declared,
        quotas: quotas,
        # A breach is never hidden behind a click, so it outranks the screen's
        # own collapse default and whatever the viewer last chose.
        quota_breached: Enum.any?(quotas, & &1.breached?),
        role_bindings: ns |> NodeManager.roles(token) |> NodeManager.ok_or([]),
        tokens: tokens,
        tokens_error: tokens_error
      ],
      load_error: load_error,
      summary: summary,
      runner_ids: Enum.map(connected_runners, &NodeManager.identifier_id/1),
      attention:
        attention(ns, token, previous, %{
          page: page,
          quotas: quotas,
          runners: runners,
          runners_read?: is_nil(runners_error),
          dlq: if(summary == :disconnected, do: [], else: summary.dlq)
        })
    }
  end

  # The namespace's partition groups, read only while their section is open:
  # the group rows among the relays read by id, as far as one page reaches,
  # each coverage as the summary states it.
  defp groups(ns, token, page) do
    broken =
      for %{group: group, complete: false} <- Map.get(page.summary, :faulted_groups, []),
          into: MapSet.new(),
          do: to_string(group)

    ns
    |> NodeManager.relay_list(token, limit: Sections.reach(), sort: :id)
    |> NodeManager.ok_or([])
    |> Enum.filter(& &1[:partitions])
    |> Enum.map(&Map.put(&1, :coverage_broken?, MapSet.member?(broken, to_string(&1.id))))
  end

  defp plugin_figures({:ok, %{rows: rows, total: total}}),
    do: %{total: total, names: Enum.map(rows, &to_string(&1.name))}

  defp plugin_figures(_failed), do: %{total: 0, names: []}

  # A whole read is shown whole: the first, one with the controller gone, and
  # every one whose relay rows answered. A later read whose rows failed, or one
  # that died, leaves the figures read before on screen and says why.
  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_apply(socket, {:ok, %{assigns: assigns} = read}) do
    first? = not socket.assigns.loaded?
    # Groups read while their section was folded keep the last ones read.
    assigns = if assigns[:groups] == :unread, do: Keyword.delete(assigns, :groups), else: assigns

    socket
    |> assign(assigns)
    |> assign(loaded?: true, load_error: read.load_error)
    |> Topology.apply_summary(socket.assigns.ns, read.summary, %{
      health: assigns[:health],
      relay_count: assigns[:relay_count],
      runners: read.runner_ids
    })
    |> track_attention(read.attention)
    |> merge_runs(read.runs)
    |> then(&if(first?, do: inspect_params(&1, &1.assigns.params), else: &1))
  end

  def refresh_apply(socket, {:ok, %{load_error: error}}), do: assign(socket, load_error: error)

  def refresh_apply(socket, {:exit, _reason}), do: assign(socket, load_error: :read_failed)

  # The namespace's problems, from the same derivation the shell and the Open
  # problems screen read, tracked against what the screen showed before.
  defp attention(ns, token, {previous, known}, read) do
    runners = if read.runners_read?, do: read.runners, else: :unread
    factories = Attention.waiting_factories(read.page)

    serving =
      ns
      |> NodeManager.serving_counts(factories, token, runners)
      |> Attention.keep_serving(known, factories)

    items =
      Attention.derive(%{
        namespaces: [
          %{
            namespace: ns,
            page: read.page,
            owns: Enum.map(read.dlq, &to_string(Map.get(&1, :relay_class))),
            quotas: read.quotas,
            serving: serving
          }
        ],
        dlq: read.dlq
      })

    {items, appeared, cleared} =
      Attention.track(Attention.by_id(previous), items, DateTime.utc_now())

    %{items: items, serving: serving, appeared: appeared, cleared: cleared}
  end

  # What came and went since the last read goes on the river; the first read
  # is the baseline, not news.
  defp track_attention(socket, attention) do
    appeared = if socket.assigns[:attention_tracked?], do: attention.appeared, else: []

    socket
    |> assign(items: attention.items, serving: attention.serving, attention_tracked?: true)
    |> FlezhaConsoleWeb.River.attention(appeared, attention.cleared)
  end

  @doc "How many of its problems Dashboard lists before linking to the rest."
  def problems_shown, do: 3

  # What the screen already knows about a selection, so opening it costs only
  # its own read.
  @impl FlezhaConsoleWeb.Inspect
  def inspect_context(socket, {"relay", id}) do
    %{ns: ns, flezha_token: token} = socket.assigns
    {_read, row, _partitions} = NodeManager.relay_and_partitions(ns, id, token)
    factory = row && row[:factory] && to_string(row.factory)

    %{
      row: row,
      serving: factory && Map.get(socket.assigns[:serving] || %{}, factory),
      factory_description: factory && Map.get(factory_descriptions(socket), factory)
    }
  end

  def inspect_context(socket, {"runner", id}) do
    %{ns: ns, flezha_token: token} = socket.assigns
    runner = Enum.find(socket.assigns.runners, &(&1.id == id)) || %{}

    relays =
      ns
      |> NodeManager.relay_list(token, limit: 20, filter: [runner: id])
      |> NodeManager.ok_or([])
      |> Enum.map(&to_string(&1.id))

    %{
      node: runner[:node],
      connected_at: runner[:connected_at],
      factories: runner[:factories] || [],
      relays: relays
    }
  end

  def inspect_context(socket, {"plugin", name}) do
    %{ns: ns, flezha_token: token} = socket.assigns

    case ns
         |> NodeManager.plugins(token, filter: [text: name])
         |> NodeManager.ok_or([])
         |> Enum.find(&(to_string(&1.name) == name)) do
      nil ->
        %{namespace: ns}

      plugin ->
        %{
          namespace: ns,
          provider: plugin.provider,
          provider_id: FlezhaConsoleWeb.PluginLive.provider_id(plugin),
          hooks: Enum.map(plugin[:hooks] || [], &to_string/1),
          relays: Enum.map(plugin[:relays] || [], &to_string/1),
          controllers: Enum.map(plugin[:controllers] || [], &to_string/1)
        }
    end
  end

  def inspect_context(_socket, _selection), do: %{}

  # Factory descriptions, read once per screen and only when a relay is
  # inspected: one listing, never a lookup per factory.
  defp factory_descriptions(%{assigns: %{factory_descriptions: %{} = known}}), do: known

  defp factory_descriptions(socket) do
    socket.assigns.ns
    |> NodeManager.factories(socket.assigns.flezha_token)
    |> NodeManager.ok_or([])
    |> Map.new(&{to_string(&1.id), Map.get(&1, :description)})
  end

  @doc """
  The headline: the namespace's condition in one sentence, as `{condition,
  text}`. `condition` is `:unreachable`, `:empty`, `:attention`, `:flowing`,
  `:quiet` or `:healthy` (nothing needs attention, rates not yet measured).
  `inbound` is the namespace's smoothed rate, as `figures/3` takes it, so a
  bursty namespace does not flip between flowing and quiet on every tick.
  """
  # Nothing is claimed before the first read.
  def headline(%{state: :loading}, _items, _inbound, ns), do: {:loading, "Reading #{ns}…"}

  def headline(%{state: :disconnected}, _items, _inbound, ns),
    do: {:unreachable, "The controller cannot be reached, so #{ns} cannot be shown."}

  def headline(_summary, [_ | _] = items, _inbound, _ns),
    do: {:attention, attention_title(items) <> "."}

  # A connected runner with no relay still has nothing running.
  def headline(%{relay_count: 0}, [], _inbound, ns),
    do: {:empty, "Nothing runs in #{ns} yet."}

  def headline(_summary, [], nil, ns),
    do: {:healthy, "Nothing in #{ns} needs attention."}

  def headline(_summary, [], inbound, ns) do
    if inbound.in + inbound.out > 0,
      do: {:flowing, "#{ns} is flowing: nothing needs attention and records are moving."},
      else:
        {:quiet,
         "#{ns} is quiet: nothing needs attention and no relay moved records over the last few readings."}
  end

  @doc """
  The headline's second line: its figures, in words. `inbound` is the
  namespace's summed rate smoothed over its newest readings, nil before two
  snapshots.
  """
  def figures(%{state: :ok} = summary, inbound) do
    healthy = health_count(summary, :healthy)
    suspended = health_count(summary, :suspended)

    [
      "#{healthy} of #{Words.count(summary.relay_count, "relay")} healthy" <>
        if(suspended > 0, do: ", #{suspended} suspended", else: ""),
      Words.count(summary.runner_count, "runner"),
      inbound && summary.relay_count > 0 && Topology.rate_label(inbound.in, " records/s in"),
      summary.parked > 0 && Words.count(summary.parked, "dead letter")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  def figures(_summary, _inbound), do: nil

  defp health_count(summary, health),
    do: Enum.find_value(summary.health, 0, &(&1.health == health && &1.count))

  # ---- Indicator tiles: each figure's tone and its words ----

  # Each `*_said` answers a tile's tone, its verdict pill (nil for none) and
  # its condition, decided together.

  defp flow_said(nil), do: {:neutral, nil, "Measuring: a rate needs two readings"}

  defp flow_said(%{in: rate} = measured) when rate > 0 do
    case Topology.byte_rate_label(measured[:bytes_in]) do
      nil -> {:positive, "Flowing", "Records arriving each second"}
      bytes -> {:positive, "Flowing", "Records arriving each second, #{bytes}"}
    end
  end

  defp flow_said(_rate), do: {:neutral, nil, "Nothing arrived since the last reading"}

  defp parked_said(0, _seen), do: {:positive, "Clear", "Every record reached its tasklet"}

  # Seen dead letters still wait in the queue, but an operator has looked.
  defp parked_said(parked, parked),
    do: {:neutral, "Seen", "Every one is marked seen, still waiting for a replay or a drop"}

  defp parked_said(_parked, _seen),
    do:
      {:warning, "Waiting", "Records a tasklet could not process, waiting for a replay or a drop"}

  # How many of the namespace's items need attention: relays when every item
  # is one, problems otherwise.
  defp attention_title(items) do
    relays = Enum.count(items, &(&1.kind == :relay))

    if relays == length(items),
      do: Words.need_attention(relays, "relay"),
      else: Words.need_attention(length(items), "problem")
  end

  # Only a healthy relay is one a runner is running.
  defp runners_foot(summary),
    do: "Running #{Words.count(health_count(summary, :healthy), "relay")}"

  defp plugin_names(%{total: total, names: names}) do
    shown = Enum.join(names, ", ")
    if total > length(names), do: "#{shown} +#{total - length(names)}", else: shown
  end

  defp plugins_condition(%{total: 0}), do: "None enabled"
  defp plugins_condition(%{total: _}), do: "Enabled in this namespace"

  defp schedules_condition([]), do: "None in this namespace"

  defp schedules_condition(schedules) do
    case schedules |> Enum.map(& &1.next_fire) |> Enum.reject(&is_nil/1) do
      [] -> "None armed"
      fires -> "Next fires at #{Format.time_of_day(Enum.min(fires, DateTime))}"
    end
  end

  defp schedules_armed(schedules) do
    armed = Enum.count(schedules, & &1.next_fire)
    "#{armed} of #{length(schedules)} armed"
  end

  # The tile shows the two fullest limits; the rest are a link away.
  defp limits_more(limits) when length(limits) > 2, do: "+#{length(limits) - 2} more in Limits"
  defp limits_more(_limits), do: "All limits"

  # The limits that apply, the breached first and then the fullest.
  defp limit_rows(quotas) do
    quotas
    |> Enum.filter(& &1.limit)
    |> Enum.sort_by(&{not &1.breached?, -use_share(&1)})
  end

  defp use_share(row), do: (row.value || 0) / max(row.limit, 1)

  # A byte counter reads in bytes, any other as the count it is.
  defp limit_use(%{kind: kind} = row) do
    if String.ends_with?(to_string(kind), "bytes"),
      do: "#{Format.bytes(row.value || 0)} of #{Format.bytes(row.limit)}",
      else: "#{row.value || 0} of #{row.limit}"
  end

  defp peak_use([]), do: nil
  defp peak_use([fullest | _rest]), do: "#{round(use_share(fullest) * 100)}%"

  # The controller answers every token the caller may see; this screen shows
  # its own namespace's.
  defp tokens(ns, token) do
    case NodeManager.list_tokens(token) do
      {:ok, rows} -> {Enum.filter(rows, &(to_string(&1.namespace) == ns)), nil}
      {:error, reason} -> {[], reason}
    end
  end

  defp save_quotas(socket, limits) do
    case NodeManager.set_namespace_quotas(socket.assigns.ns, limits, socket.assigns.flezha_token) do
      {:error, reason} ->
        assign(socket, quota_error: reason)

      _ok ->
        socket
        |> assign(quota_form: nil, quota_error: nil)
        |> refresh()
        |> put_flash(:info, "Quotas updated.")
    end
  end

  # ---- Recent runs ----
  #
  # The namespace's ended runs from the relay history, newest first. The
  # newest page rides Dashboard's background read; growing the listing past the
  # rows it holds reads the next older page by the history's cursor.

  @runs_page 20
  @runs_id "recent-runs"

  defp recent_runs(ns, token, before \\ nil),
    do: NodeManager.ended_runs(ns, %{}, %{limit: @runs_page, before: before}, token)

  # A grown listing keeps the older pages it read, under the newest page.
  defp merge_runs(socket, nil), do: socket

  defp merge_runs(socket, {:ok, %{records: fresh, next: next}}) do
    if socket.assigns.runs_grown?,
      do: assign(socket, runs: newest_first(fresh ++ socket.assigns.runs), runs_error: nil),
      else: assign(socket, runs: fresh, runs_next: next, runs_error: nil)
  end

  defp merge_runs(socket, {:error, reason}), do: assign(socket, runs_error: reason)

  defp newest_first(records),
    do: records |> Enum.uniq() |> Enum.sort_by(&(&1["ts_us"] || 0), :desc)

  def section_opened(socket, key) when key in [@runs_id, "partition-groups"], do: refresh(socket)
  def section_opened(socket, _key), do: socket

  @doc false
  def listing_grown(socket, @runs_id), do: read_older_runs(socket)
  def listing_grown(socket, "problems-" <> _namespace), do: refresh(socket)
  def listing_grown(socket, _id), do: socket

  defp read_older_runs(%{assigns: %{runs_next: next, runs: runs}} = socket)
       when is_binary(next) do
    if Sections.shown(socket.assigns.paging, @runs_id) > length(runs) do
      %{ns: ns, flezha_token: token} = socket.assigns

      FlezhaConsoleWeb.Live.Refresh.start_once(socket, :runs_loading?, :older_runs, fn ->
        recent_runs(ns, token, next)
      end)
    else
      socket
    end
  end

  defp read_older_runs(socket), do: socket

  defp on_older_runs(socket) do
    if connected?(socket),
      do:
        FlezhaConsoleWeb.Live.Refresh.on_answer(
          socket,
          :older_runs,
          :runs_loading?,
          &older_runs_answered/2
        ),
      else: socket
  end

  # A listing grown twice while a page was read asks for the next at once.
  defp older_runs_answered(socket, {:ok, {:ok, %{records: older, next: next}}}) do
    socket
    |> assign(
      runs: newest_first(socket.assigns.runs ++ older),
      runs_next: next,
      runs_grown?: true,
      runs_error: nil
    )
    |> read_older_runs()
  end

  defp older_runs_answered(socket, {:ok, {:error, reason}}),
    do: assign(socket, runs_error: reason)

  defp older_runs_answered(socket, {:exit, _reason}),
    do: assign(socket, runs_error: :read_failed)

  @doc "How many of the runs a listing shows did not complete."
  def not_completed(runs, paging) do
    runs
    |> Enum.take(Sections.shown(paging, @runs_id))
    |> Enum.count(&(&1["outcome"] != "completed"))
  end

  # ---- Section digests: what a folded section holds, in a few words ----

  defp limits_digest(_quotas, nil), do: "no limits declared"

  defp limits_digest(quotas, _declared) do
    case Enum.filter(quotas, & &1.breached?) do
      [] -> "#{Words.count(Enum.count(quotas, & &1.limit), "limit")} set, none reached"
      breached -> "#{Words.join(Enum.map(breached, &Words.humanize(&1.kind)))} at the limit"
    end
  end

  @token_statuses [
    {"active", "Active"},
    {"revoked", "Revoked"},
    {"expired", "Expired"},
    {"all", "All"}
  ]

  @doc "The token status filter's choices, each with how many tokens it holds."
  def token_choices(tokens) do
    for {value, label} <- @token_statuses do
      {value, label, length(tokens_with_status(tokens, value))}
    end
  end

  @doc "The tokens `status` lists, soonest expiry first and those that never expire last."
  def tokens_with_status(tokens, status) do
    tokens
    |> Enum.filter(&(status == "all" or to_string(&1.status) == status))
    |> Enum.sort_by(&expiry_order(&1[:expires_at]))
  end

  defp expiry_order(at) when is_integer(at), do: {0, at}
  defp expiry_order(:never), do: {1, 0}
  defp expiry_order(_unknown), do: {2, 0}

  # Three days: long enough to reissue before a weekend.
  defp expiry_tone(%{status: :active, expires_at: at}) when is_integer(at) do
    if at - System.system_time(:second) < 3 * 86_400, do: :warning
  end

  defp expiry_tone(_row), do: nil

  defp access_digest(bindings, tokens) do
    active = Enum.count(tokens, &(&1.status == :active))
    "#{Words.count(length(bindings), "principal")} bound · #{Words.count(active, "active token")}"
  end

  defp groups_digest(:unread, 0), do: "coverage whole"
  defp groups_digest(:unread, broken), do: "#{broken} with broken coverage"

  defp groups_digest(groups, _broken) do
    case Enum.count(groups, & &1.coverage_broken?) do
      0 -> Words.count(length(groups), "group") <> ", coverage whole"
      faulted -> Words.count(length(groups), "group") <> ", #{faulted} with broken coverage"
    end
  end

  defp runs_digest([], _next), do: "none yet"

  defp runs_digest([latest | _] = runs, next) do
    count = Words.count(length(runs), "run") <> if(next, do: " or more", else: "")
    "#{count}, latest #{Format.relative(FlezhaConsoleWeb.LogLines.time(latest), :millisecond)}"
  end

  defp runners_digest(runners, marks) do
    [
      Words.count(length(runners), "runner") <> " connected",
      marks != [] && Words.count(length(marks), "dropped process", "dropped processes")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp quota_tone(%{breached?: true}), do: "negative"
  defp quota_tone(_row), do: nil
end
