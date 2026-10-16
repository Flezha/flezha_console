defmodule FlezhaUiWeb.NamespaceLive.Show do
  @moduledoc """
  A namespace's Home: a headline sentence, the namespace's open problems, the
  live map of its data plane, the event river, and its administration folded
  below — limits, access, partition groups, finished relays and runners.

  It replaces both the former dashboard and the namespace overview, and is the
  only screen that renders the namespace's data-plane summary. Selecting
  anything on the map inspects it in place.
  """

  use FlezhaUiWeb, :live_view

  # The map reads its rates from snapshot deltas, so this screen ticks at the
  # rate those deltas are worth measuring over. A runner flip is the one state
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
        runs: %{},
        plugin_pairs: [],
        groups: [],
        runners: [],
        runner_marks: [],
        declared: nil,
        quotas: [],
        quota_breached: false,
        role_bindings: [],
        items: [],
        expanded: MapSet.new(),
        map: nil,
        rows: [],
        finished: [],
        finished_error: nil,
        finished_loading?: false,
        rescale: nil,
        quota_form: nil,
        quota_error: nil,
        tokens: [],
        tokens_error: nil,
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
    {:noreply, socket |> inspect_params(params) |> assign_map()}
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

  # Opening a stack draws its member lanes from what the last tick read.
  @impl true
  def handle_event("map_expand", %{"id" => key}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, socket |> assign(expanded: expanded) |> assign_map()}
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
    # partition group; the summary and the map are built from it, not from a
    # read per relay.
    {rows, load_error} = NodeManager.ok_or_error(NodeManager.relay_rows(ns, token), [])
    groups = rows |> NodeManager.partition_groups(token) |> with_group_health(rows)
    declared = NodeManager.ok_or(NodeManager.namespace_record(ns, token), nil)
    quotas = NodeManager.quota_usage(ns, declared && declared.quotas, token)

    runners =
      ns |> NodeManager.runners(token) |> NodeManager.ok_or([]) |> FlezhaUiWeb.Runners.rows()

    socket =
      socket
      |> assign(
        loaded?: true,
        rows: rows,
        runs: ns |> NodeManager.relay_runs(token) |> NodeManager.ok_or(%{}),
        plugin_pairs: ns |> NodeManager.relay_plugins(token) |> NodeManager.ok_or([]),
        groups: groups,
        runners: runners,
        runner_marks: ns |> NodeManager.dropped_runners(token) |> NodeManager.ok_or([]),
        declared: declared,
        quotas: quotas,
        # A breach is never hidden behind a click, so it outranks the screen's
        # own collapse default and whatever the viewer last chose.
        quota_breached: Enum.any?(quotas, & &1.breached?),
        role_bindings: ns |> NodeManager.roles(token) |> NodeManager.ok_or([]),
        load_error: load_error
      )
      |> Topology.load_summary(ns, %{rows: rows, groups: groups})
      |> track_attention()
      |> load_tokens()

    assign_map(socket)
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

    # The first read is the baseline, not news.
    appeared = if socket.assigns[:attention_tracked?], do: appeared, else: []

    socket
    |> assign(items: items, attention_tracked?: true)
    |> FlezhaUiWeb.River.attention(appeared, cleared)
  end

  # The map is rebuilt from what the last tick read whenever the selection or
  # an opened stack changes, so neither costs a controller call.
  defp assign_map(%{assigns: %{topology: %{kind: :summary, state: :ok} = summary}} = socket) do
    %{assigns: a} = socket

    map =
      Topology.map(%{
        namespace: a.ns,
        rows: a.rows,
        runners: a.runners,
        plugins: a.plugin_pairs,
        runs: a.runs,
        rates: a.topology_state.rates,
        history: a.topology_state.history,
        parked: summary.parked,
        faulted_groups: NodeManager.faulted_group_ids(a.groups),
        expanded: a.expanded,
        selected: selection(a[:inspected])
      })

    assign(socket, map: map)
  end

  defp assign_map(socket), do: assign(socket, map: nil)

  defp selection(%{kind: kind, id: id}), do: {String.to_existing_atom(kind), id}
  defp selection(_none), do: nil

  # What the screen already knows about a selection, so opening it costs only
  # its own read.
  @impl FlezhaUiWeb.Inspect
  def inspect_context(socket, {"relay", id}) do
    %{rows: rows, topology_state: state} = socket.assigns
    row = NodeManager.relay_row(rows, id)
    factory = row && row[:factory] && to_string(row.factory)

    %{
      row: row,
      rate: Map.get(state.rates, id),
      history: state.history |> Map.get(id, []) |> Enum.reverse(),
      factory_description: factory && Map.get(factory_descriptions(socket), factory)
    }
  end

  def inspect_context(socket, {"runner", id}) do
    %{rows: rows, runners: runners, ns: ns, flezha_token: token} = socket.assigns
    runner = Enum.find(runners, &(&1.id == id)) || %{}

    factories =
      ns
      |> NodeManager.factory_catalog(token)
      |> NodeManager.ok_or([])
      |> NodeManager.factories_by_runner()
      |> Map.get(id, [])

    %{
      pid: runner[:pid],
      factories: factories,
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
  """
  # Nothing is claimed before the first read.
  def headline(%{state: :loading}, _items, _rates, ns), do: {:loading, "Reading #{ns}…"}

  def headline(%{state: :disconnected}, _items, _rates, ns),
    do: {:unreachable, "The controller cannot be reached, so #{ns} cannot be shown."}

  def headline(%{state: :empty}, _items, _rates, ns),
    do: {:empty, "Nothing runs in #{ns} yet."}

  def headline(_summary, [_ | _] = items, _rates, _ns) do
    relays = Enum.count(items, &(&1.kind == :relay))

    text =
      if relays == length(items),
        do:
          "#{Words.count(relays, "relay")} #{if relays == 1, do: "needs", else: "need"} attention.",
        else:
          "#{Words.count(length(items), "problem")} #{if length(items) == 1, do: "needs", else: "need"} attention."

    {:attention, text}
  end

  def headline(_summary, [], rates, ns) when rates == %{},
    do: {:healthy, "Every relay in #{ns} is healthy."}

  def headline(_summary, [], rates, ns) do
    if Enum.any?(rates, fn {_id, rate} -> rate.in + rate.out > 0 end),
      do: {:flowing, "#{ns} is flowing: every relay is healthy and records are moving."},
      else:
        {:quiet,
         "#{ns} is quiet: every relay is healthy and none moved records since the last reading."}
  end

  @doc "The headline's second line: its figures, in words."
  def figures(%{state: :ok} = summary, rows, rates) do
    healthy = Enum.count(rows, &(NodeManager.row_health(&1) == :healthy))
    inbound = rates |> Map.values() |> Enum.map(& &1.in) |> Enum.sum()

    [
      "#{healthy} of #{Words.count(length(rows), "relay")} healthy",
      Words.count(summary.runner_count, "runner"),
      rates != %{} && "#{Float.round(inbound / 1, 1)} records/s in",
      summary.parked > 0 && "#{summary.parked} parked"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  def figures(_summary, _rows, _rates), do: nil

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
    "#{Words.count(length(finished), "relay")}, latest #{Format.token_expiry(latest)}"
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
