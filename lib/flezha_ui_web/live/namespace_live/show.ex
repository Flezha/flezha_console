defmodule FlezhaUiWeb.NamespaceLive.Show do
  @moduledoc """
  A namespace's Home: a headline sentence, the namespace's open problems,
  indicator tiles for everything the operator reaches and then for this
  namespace, the event river, and its administration folded below — limits,
  access, partition groups, finished relays and runners.

  It replaces both the former dashboard and the namespace overview, and is the
  only screen that renders the namespace's data-plane summary. The system
  tiles read the shell pulse, which this screen asks for fleet figures
  (`pulse_fleet`); the namespace tiles read this screen's own tick.
  """

  use FlezhaUiWeb, :live_view

  # The flow figures are snapshot deltas, so this screen ticks at the rate
  # those deltas are worth measuring over. A runner flip is the one state
  # change worth showing before the next tick.
  use FlezhaUiWeb.Live.Refresh,
    every: 2_000,
    on_events: [:runner_connected, :runner_disconnected, :runner_dropped, :runner_readmitted]

  use FlezhaUiWeb.Topology
  use FlezhaUiWeb.Live.Launcher
  use FlezhaUiWeb.Live.RunnerActions
  use FlezhaUiWeb.Attention
  use FlezhaUiWeb.River
  use FlezhaUiWeb.Inspect, kinds: ~w(relay runner plugin)

  # The namespace's data plane is what the screen is for; everything that
  # administers the namespace is folded away until asked for. A breached quota
  # overrides that — see the `forced` section in the template.
  use FlezhaUiWeb.Live.Sections,
    open: %{
      "quotas" => false,
      "access" => false,
      "partition-groups" => false,
      "finished-relays" => false,
      "runners" => false
    }

  alias FlezhaUi.Format
  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Attention
  alias FlezhaUiWeb.Topology

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
        confirm_stop: nil,
        load_error: nil,
        pulse_fleet: true,
        plugin_pairs: [],
        schedules: [],
        groups: [],
        runners: [],
        runner_marks: [],
        declared: nil,
        quotas: [],
        quota_breached: false,
        role_bindings: [],
        items: [],
        rows: [],
        finished: [],
        finished_error: nil,
        finished_loading?: false,
        rescale: nil,
        quota_form: nil,
        quota_error: nil,
        tokens: [],
        tokens_error: nil,
        token_status: "active",
        token_issue: nil,
        confirm_revoke: nil,
        role_bind: nil,
        confirm_unbind: nil,
        factory_descriptions: nil
      )
      |> refresh_when_connected()
      |> load_finished()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, inspect_params(socket, params)}
  end

  # The dialogs and the launcher, any of which a row could move underneath.
  @impl FlezhaUiWeb.Live.Refresh
  def refresh_paused?(socket) do
    FlezhaUiWeb.Live.Launcher.open?(socket) or
      Enum.any?(
        ~w(confirm_stop rescale quota_form token_issue confirm_revoke role_bind confirm_unbind)a,
        &(socket.assigns[&1] != nil)
      )
  end

  # ---- Tokens ----
  #
  # An issued token is held in the issue dialog's assign alone, shown once and
  # dropped when the dialog closes: never flashed, logged or put in a URL.

  @impl true
  def handle_event("open_issue", _params, socket) do
    form = %{"principal" => "", "role" => "", "ttl" => "86400", "label" => ""}
    {:noreply, assign(socket, token_issue: %{form: form, error: nil, issued: nil})}
  end

  @impl true
  def handle_event("close_issue", _params, socket) do
    {:noreply, socket |> assign(token_issue: nil) |> refresh()}
  end

  @impl true
  def handle_event("issue_token", %{"token" => params}, %{assigns: %{token_issue: %{}}} = socket) do
    %{token_issue: issue, ns: ns, flezha_token: token} = socket.assigns
    form = Map.merge(issue.form, params)
    label = String.trim(form["label"] || "")
    opts = if label == "", do: [], else: [label: label]

    with {:ok, principal, role} <- principal_and_role(form),
         {:ok, ttl} <- parse_ttl(form["ttl"]),
         {:ok, issued} <- NodeManager.issue_token(principal, ns, role, [ttl: ttl] ++ opts, token) do
      {:noreply, assign(socket, token_issue: %{issue | form: form, error: nil, issued: issued})}
    else
      {:error, error} ->
        {:noreply, assign(socket, token_issue: %{issue | form: form, error: error})}
    end
  end

  def handle_event("issue_token", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("token_status", %{"value" => status}, socket)
      when status in ~w(active revoked expired all),
      do: {:noreply, assign(socket, token_status: status)}

  @impl true
  def handle_event("confirm_revoke", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_revoke: Enum.find(socket.assigns.tokens, &(&1.id == id)))}
  end

  @impl true
  def handle_event("cancel_revoke", _params, socket) do
    {:noreply, assign(socket, confirm_revoke: nil)}
  end

  @impl true
  def handle_event("revoke_token", %{"id" => id}, socket) do
    socket = assign(socket, confirm_revoke: nil)

    case NodeManager.revoke_token(id, socket.assigns.flezha_token) do
      {:ok, _row} ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Token #{id} revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason, "the revocation"))}
    end
  end

  # ---- Role bindings ----

  @impl true
  def handle_event("open_bind", _params, socket) do
    {:noreply, assign(socket, role_bind: %{form: %{"principal" => "", "role" => ""}, error: nil})}
  end

  @impl true
  def handle_event("close_bind", _params, socket) do
    {:noreply, assign(socket, role_bind: nil)}
  end

  @impl true
  def handle_event("bind_role", %{"binding" => params}, %{assigns: %{role_bind: %{}}} = socket) do
    %{role_bind: bind, ns: ns, flezha_token: token} = socket.assigns
    form = Map.merge(bind.form, params)

    with {:ok, principal, role} <- principal_and_role(form),
         {:ok, _bound} <- NodeManager.bind_role(principal, role, ns, token) do
      {:noreply,
       socket
       |> assign(role_bind: nil)
       |> refresh()
       |> put_flash(:info, "#{principal} bound as #{role} in #{ns}.")}
    else
      {:error, error} -> {:noreply, assign(socket, role_bind: %{bind | form: form, error: error})}
    end
  end

  def handle_event("bind_role", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("confirm_unbind", %{"principal" => principal} = params, socket) do
    role = if params["role"] in [nil, ""], do: nil, else: params["role"]
    namespace = params["namespace"] || socket.assigns.ns

    {:noreply,
     assign(socket, confirm_unbind: %{principal: principal, role: role, namespace: namespace})}
  end

  @impl true
  def handle_event("cancel_unbind", _params, socket) do
    {:noreply, assign(socket, confirm_unbind: nil)}
  end

  @impl true
  def handle_event("unbind_role", %{"principal" => principal} = params, socket) do
    role = if params["role"] in [nil, ""], do: nil, else: params["role"]
    socket = assign(socket, confirm_unbind: nil)

    case NodeManager.unbind_role(principal, role, socket.assigns.flezha_token) do
      {:ok, _unbound} ->
        message =
          if role,
            do: "#{role} unbound from #{principal}.",
            else: "#{principal}'s whole binding removed."

        {:noreply, socket |> refresh() |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason, "the unbind"))}
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

  # What both the issue and the bind dialog ask for, trimmed and required.
  defp principal_and_role(form) do
    principal = String.trim(form["principal"] || "")
    role = String.trim(form["role"] || "")

    cond do
      principal == "" -> {:error, "A principal is required."}
      role == "" -> {:error, "A role is required."}
      true -> {:ok, principal, role}
    end
  end

  @doc """
  The role a principal is bound to or issued, picked from every role there
  is, each with what it allows.
  """
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :testid, :string, required: true

  def role_field(assigns) do
    assigns = assign(assigns, :roles, FlezhaUiWeb.Glossary.roles())

    ~H"""
    <fieldset class="fui-field" data-testid={@testid}>
      <legend class="fui-label">Role</legend>
      <div class="fui-choices">
        <label :for={{role, meaning} <- @roles} class="fui-choice">
          <input
            type="radio"
            name={@name}
            value={role}
            checked={@value == role}
            required
            data-testid={"#{@testid}-#{role}"}
          />
          <span class="grid gap-1">
            <span class="fui-num font-medium">{role}</span>
            <span class="fui-quiet text-sm">{meaning}</span>
          </span>
        </label>
      </div>
    </fieldset>
    """
  end

  # A lifetime is a positive number of seconds or `never`, as core takes it.
  defp parse_ttl(raw) do
    case String.trim(raw || "") do
      "never" ->
        {:ok, "never"}

      text ->
        case Integer.parse(text) do
          {seconds, ""} when seconds > 0 -> {:ok, seconds}
          _invalid -> {:error, "The lifetime must be a positive number of seconds or never."}
        end
    end
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    %{ns: ns, flezha_token: token} = socket.assigns

    # One registry dump answers every relay's health, node, factory, runner and
    # partition group; the summary and the tiles are built from it, not from a
    # read per relay.
    {rows, load_error} = NodeManager.ok_or_error(NodeManager.relay_rows(ns, token), [])
    groups = rows |> NodeManager.partition_groups(token) |> with_group_health(rows)
    declared = NodeManager.ok_or(NodeManager.namespace_record(ns, token), nil)
    quotas = NodeManager.quota_usage(ns, declared && declared.quotas, token)

    {connected_runners, runners_error} =
      ns |> NodeManager.runners(token) |> NodeManager.ok_or_error([])

    socket
    |> assign(
      loaded?: true,
      rows: rows,
      plugin_pairs: ns |> NodeManager.relay_plugins(token) |> NodeManager.ok_or([]),
      schedules:
        token
        |> NodeManager.schedule_list()
        |> NodeManager.ok_or([])
        |> FlezhaUiWeb.ScheduleLive.rows(ns),
      groups: groups,
      runners:
        FlezhaUiWeb.Runners.rows(
          connected_runners,
          ns
          |> NodeManager.factory_catalog(token)
          |> NodeManager.ok_or([])
          |> NodeManager.factories_by_runner(),
          rows
        ),
      runners_read?: is_nil(runners_error),
      runner_marks: ns |> NodeManager.dropped_runners(token) |> NodeManager.ok_or([]),
      declared: declared,
      quotas: quotas,
      # A breach is never hidden behind a click, so it outranks the screen's
      # own collapse default and whatever the viewer last chose.
      quota_breached: Enum.any?(quotas, & &1.breached?),
      role_bindings: ns |> NodeManager.roles(token) |> NodeManager.ok_or([]),
      load_error: load_error
    )
    |> Topology.load_summary(ns, %{
      rows: rows,
      groups: groups,
      runners: Enum.map(connected_runners, &NodeManager.identifier_id/1)
    })
    |> track_attention()
    |> load_tokens()
  end

  # The namespace's problems, from the same derivation the shell and the Open
  # problems screen read; what came and went since the last tick goes on the
  # river.
  defp track_attention(socket) do
    %{ns: ns, rows: rows, groups: groups, quotas: quotas, items: previous} = socket.assigns

    items =
      Attention.derive(%{
        namespaces: [
          %{
            namespace: ns,
            rows: rows,
            faulted_groups: NodeManager.faulted_group_ids(groups),
            quotas: quotas
          }
        ]
      })

    {items, appeared, cleared} =
      Attention.track(Attention.by_id(previous), items, DateTime.utc_now())

    serving = serving(Enum.take(items, problems_shown()), socket)
    items = Attention.put_serving(items, serving)

    # The first read is the baseline, not news.
    appeared = if socket.assigns[:attention_tracked?], do: appeared, else: []

    socket
    |> assign(items: items, serving: serving, attention_tracked?: true)
    |> FlezhaUiWeb.River.attention(appeared, cleared)
  end

  @doc "How many of its problems Home lists before linking to the rest."
  def problems_shown, do: 3

  # How many runners serve the factories the shown problems wait on: whether
  # a suspended relay can wake depends on it. At most one read per shown
  # problem, and none when no runner is connected at all. A read that fails
  # leaves its factory unknown rather than unserved.
  defp serving(shown, %{assigns: %{ns: ns, runners: runners, flezha_token: token} = assigns}) do
    factories = Attention.waiting_factories(shown)

    if runners == [] and assigns.runners_read? do
      Map.new(factories, &{&1, 0})
    else
      factories
      |> Map.new(&{&1, NodeManager.serving_count(ns, &1, token)})
      |> Map.reject(fn {_factory, count} -> is_nil(count) end)
    end
  end

  # What the screen already knows about a selection, so opening it costs only
  # its own read.
  @impl FlezhaUiWeb.Inspect
  def inspect_context(socket, {"relay", id}) do
    %{rows: rows, topology_state: state} = socket.assigns
    row = NodeManager.relay_row(rows, id)
    factory = row && row[:factory] && to_string(row.factory)

    %{
      row: row,
      serving: factory && Map.get(socket.assigns[:serving] || %{}, factory),
      rate: Map.get(state.rates, id),
      history: state.history |> Map.get(id, []) |> Enum.reverse(),
      factory_description: factory && Map.get(factory_descriptions(socket), factory)
    }
  end

  def inspect_context(socket, {"runner", id}) do
    %{rows: rows, runners: runners} = socket.assigns
    runner = Enum.find(runners, &(&1.id == id)) || %{}

    %{
      node: runner[:node],
      connected_at: runner[:connected_at],
      factories: runner[:factories] || [],
      relays:
        for(row <- rows, to_string(row[:runner]) == id, do: to_string(row.id)) |> Enum.sort()
    }
  end

  def inspect_context(socket, {"plugin", name}) do
    %{ns: ns, flezha_token: token} = socket.assigns

    case ns
         |> NodeManager.plugins(token)
         |> NodeManager.ok_or([])
         |> Enum.find(&(to_string(&1.name) == name)) do
      nil ->
        %{namespace: ns}

      plugin ->
        %{
          namespace: ns,
          provider: plugin.provider,
          provider_id: FlezhaUiWeb.PluginLive.provider_id(plugin),
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
  `:quiet` or `:healthy` (every relay healthy, rates not yet measured).
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
    do: {:healthy, "Every relay in #{ns} is healthy."}

  def headline(_summary, [], inbound, ns) do
    if inbound.in + inbound.out > 0,
      do: {:flowing, "#{ns} is flowing: every relay is healthy and records are moving."},
      else:
        {:quiet,
         "#{ns} is quiet: every relay is healthy and none moved records over the last few readings."}
  end

  @doc """
  The headline's second line: its figures, in words. `inbound` is the
  namespace's summed rate smoothed over its newest readings, nil before two
  snapshots.
  """
  def figures(%{state: :ok} = summary, rows, inbound) do
    healthy = Enum.count(rows, &(NodeManager.row_health(&1) == :healthy))

    [
      "#{healthy} of #{Words.count(length(rows), "relay")} healthy",
      Words.count(summary.runner_count, "runner"),
      inbound && Topology.rate_label(inbound.in, " records/s in"),
      summary.parked > 0 && Words.count(summary.parked, "dead letter")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  def figures(_summary, _rows, _inbound), do: nil

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

  defp parked_said(0), do: {:positive, "Clear", "Every record reached its tasklet"}

  defp parked_said(_parked),
    do:
      {:negative, "Waiting",
       "Records a tasklet could not process, waiting for a replay or a drop"}

  defp health_total(health), do: health |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  # Relays by verdict: painted in the worst, whose count is the pill.
  defp health_said([]), do: {:neutral, nil, "None running"}

  defp health_said(health) do
    worst =
      health |> Enum.map(fn {verdict, _} -> Words.tone(:health, verdict) end) |> Words.worst()

    verdict =
      Enum.find_value(health, "Healthy", fn {verdict, count} = bucket ->
        if count > 0 and verdict != :healthy and Words.tone(:health, verdict) == worst,
          do: counted(bucket)
      end)

    condition =
      case health do
        [{:healthy, _count}] -> "All healthy"
        _mixed -> Enum.map_join(health, " · ", &counted/1)
      end

    {worst, verdict, condition}
  end

  defp counted({verdict, count}), do: "#{count} #{String.downcase(Words.text(:health, verdict))}"

  # No runner is a problem only while there are relays waiting for one.
  defp runners_said(nil, _relays), do: {:neutral, nil}
  defp runners_said(0, 0), do: {:neutral, nil}
  defp runners_said(0, _relays), do: {:warning, "Needed"}
  defp runners_said(_runners, _relays), do: {:positive, "Connected"}

  defp nodes_said(nil), do: {:neutral, nil, "Not read yet"}
  defp nodes_said([]), do: {:negative, "Unreachable", "None reachable"}

  defp nodes_said(nodes) do
    case Enum.find(nodes, & &1.connected?) do
      nil -> {:negative, "Disconnected", "This console is connected to none of them"}
      node -> {:positive, "Connected", "This console is connected to #{node.name}"}
    end
  end

  defp problems_said([]), do: {:positive, "Clear", "Nothing needs attention"}

  defp problems_said(items) do
    tone = Attention.worst(items)
    verdict = if tone == :negative, do: "Urgent", else: "Attention"
    {tone, verdict, need_attention(length(items), "problem")}
  end

  # How many of the namespace's items need attention: relays when every item
  # is one, problems otherwise.
  defp attention_title(items) do
    relays = Enum.count(items, &(&1.kind == :relay))

    if relays == length(items),
      do: need_attention(relays, "relay"),
      else: need_attention(length(items), "problem")
  end

  defp need_attention(count, noun),
    do: "#{Words.count(count, noun)} #{if count == 1, do: "needs", else: "need"} attention"

  defp controller_said(nil, _fleet), do: {:negative, "Down", "This console cannot reach it"}

  defp controller_said(_node, %{breaches: breaches}) when breaches > 0,
    do:
      {:negative, "Breach",
       "#{Words.count(breaches, "durability breach", "durability breaches")} past their RPO"}

  defp controller_said(_node, %{status: %{durability_posture: posture}}) do
    said = Words.say(:durability_posture, posture)
    {if(said.tone == :neutral, do: :positive, else: said.tone), "Up", said.text}
  end

  defp controller_said(_node, _fleet), do: {:positive, "Up", "Connected"}

  # A registry row names the runner that last hosted a relay, so only a
  # running relay's runner is counted as serving it.
  defp runners_foot(rows) do
    running = Enum.count(rows, &(&1[:runner] && NodeManager.row_health(&1) == :healthy))
    "Running #{Words.count(running, "relay")}"
  end

  defp plugin_ids(pairs) do
    pairs
    |> Enum.flat_map(fn {_relay, plugins} -> Enum.map(plugins, &elem(&1, 0)) end)
    |> Enum.uniq()
  end

  defp plugin_count(pairs), do: length(plugin_ids(pairs))

  defp plugin_names(pairs) do
    ids = plugin_ids(pairs)
    shown = ids |> Enum.take(2) |> Enum.map_join(", ", &to_string/1)
    if length(ids) > 2, do: "#{shown} +#{length(ids) - 2}", else: shown
  end

  defp plugins_condition(pairs) do
    case Enum.count(pairs, fn {_relay, plugins} -> plugins != [] end) do
      0 -> "None bound"
      relays -> "Bound to #{Words.count(relays, "relay")}"
    end
  end

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
  defp load_tokens(socket) do
    %{ns: ns, flezha_token: token} = socket.assigns

    case NodeManager.list_tokens(token) do
      {:ok, rows} ->
        assign(socket,
          tokens: Enum.filter(rows, &(to_string(&1.namespace) == ns)),
          tokens_error: nil
        )

      {:error, reason} ->
        assign(socket, tokens: [], tokens_error: reason)
    end
  end

  # A group is as healthy as its sickest member, by the controller's rank.
  defp with_group_health(groups, rows) do
    rank = NodeManager.health_verdicts()
    health = Map.new(rows, &{to_string(&1.id), NodeManager.row_health(&1)})

    Enum.map(groups, fn group ->
      worst =
        group.members
        |> Enum.map(&Map.get(health, to_string(&1.id), :unknown))
        |> Enum.max_by(&Enum.find_index(rank, fn h -> h == &1 end), fn -> :unknown end)

      Map.put(group, :health, worst)
    end)
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

  defp groups_digest(groups) do
    case Enum.count(groups, &is_map(&1.coverage)) do
      0 -> Words.count(length(groups), "group") <> ", coverage whole"
      faulted -> Words.count(length(groups), "group") <> ", #{faulted} with broken coverage"
    end
  end

  defp finished_digest(_finished, true), do: "reading…"
  defp finished_digest([], false), do: "none in the retention window"

  defp finished_digest(finished, false) do
    latest = finished |> Enum.map(&(&1[:finished_at] || 0)) |> Enum.max()
    "#{Words.count(length(finished), "relay")}, latest #{Format.unix_time(latest, :second)}"
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
