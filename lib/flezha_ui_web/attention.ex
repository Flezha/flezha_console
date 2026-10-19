defmodule FlezhaUiWeb.Attention do
  @moduledoc """
  The console's open problems, derived in one place from reads it already
  makes.

  Pure: `derive/1` takes what the controller answered and answers attention
  items: only a condition Flezha or the operator handles is one. Home lists
  its namespace's items, the shell's pulse counts them for every reachable
  namespace, and `/problems` lists them all.

  An item is

      %{id:, kind:, severity: :warning | :negative, namespace:, object: %{kind:, id:},
        what:, condition:, actions: [action], first_seen:}

  where `condition` is its facts, as `condition/1` renders them, and the
  severity follows who handles it: negative for the operator, warning for
  Flezha. A relay item carries `relay: %{state:, factory:, serving:}` in place
  of `condition`, which `FlezhaUiWeb.RelayState.summary/1` renders with the
  diagnosis once asked; `serving` is how many runners serve its factory, nil
  when unread. It names no runner: a registry row names the one that last
  hosted the relay, not the one bound to it now, which only the relay's own
  Overwatch reads.

  and an action is `%{label:, navigate:}` or `%{label:, do: :diagnose,
  operation:, namespace:, relay:}`; `operation` names the controller verb that
  gates it. `first_seen` is when this console first saw the item, kept across
  reads by `track/3`.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.RelayState

  # Named exactly, so a host's own events cannot be swallowed.
  @events ~w(problem_diagnose)

  @doc """
  Embeds the problem list in a host LiveView: the inline diagnosis its
  Diagnose action answers. The host calls `attention_init/1` in mount.
  """
  defmacro __using__(_opts) do
    events = @events

    quote do
      import FlezhaUiWeb.Attention, only: [attention_init: 1, problem_list: 1]

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) when event in unquote(events) do
        {:noreply, FlezhaUiWeb.Attention.handle_event(event, params, socket)}
      end
    end
  end

  @doc "Initial assigns for a host. Call in mount."
  def attention_init(socket), do: assign(socket, diagnoses: %{})

  @doc false
  # On request only: the controller reads verdicts, runners, dead letters and
  # the input log to answer it, so it never rides a tick.
  def handle_event(
        "problem_diagnose",
        %{"namespace" => ns, "relay" => id, "item" => item},
        socket
      ) do
    answer =
      case NodeManager.diagnose_relay(ns, id, socket.assigns.flezha_token) do
        {:ok, diagnosis} -> %{diagnosis: diagnosis, error: nil}
        {:error, reason} -> %{diagnosis: nil, error: reason}
      end

    update(socket, :diagnoses, &Map.put(&1, item, answer))
  end

  @doc """
  Every item the reads in `input` reveal. Each key is optional:

    * `:namespaces` — `[%{namespace:, rows:, faulted_groups:, quotas:, serving:}]`,
      `serving` mapping each factory `waiting_factories/1` names to how many
      runners serve it;
    * `:dlq` — the dead-letter statistics;
    * `:breaches` — references past their RPO target;
    * `:verdicts` — recent stall verdicts, as `FlezhaUiWeb.Topology.stall/1` answers;
    * `:authz` — the `NodeManager.authz_status/1` map;
    * `:skew` — an `{:api_missing, module, function, arity}` a read answered.
  """
  def derive(input) do
    namespaced =
      Enum.flat_map(Map.get(input, :namespaces, []), fn ns ->
        faulted = Map.get(ns, :faulted_groups, [])

        relay_items(ns.namespace, Map.get(ns, :rows, []), faulted, Map.get(ns, :serving, %{})) ++
          group_items(ns.namespace, faulted) ++
          quota_items(ns.namespace, Map.get(ns, :quotas, []))
      end)

    namespaced ++
      dead_letter_items(Map.get(input, :dlq, [])) ++
      rpo_items(Map.get(input, :breaches, [])) ++
      stall_items(Map.get(input, :verdicts, [])) ++
      bootstrap_items(Map.get(input, :authz)) ++
      skew_items(Map.get(input, :skew))
  end

  @doc """
  The items for a namespace's relays: each relay whose condition Flezha or
  the operator handles — surfaced whatever its throughput, since a stuck
  relay is exactly the one whose counters stopped moving — and one item per
  factory no runner serves, holding every relay that waits only on it.

  `serving` maps a factory to how many runners serve it; a factory it does
  not hold is unread, and a suspended relay of an unread factory is no item.
  """
  def relay_items(namespace, rows, faulted_groups \\ [], serving \\ %{}) do
    {items, waiting} =
      rows
      |> Enum.map(&relay_item(namespace, &1, faulted_groups, serving))
      |> Enum.reduce({[], []}, fn
        {:item, item}, {items, waiting} -> {[item | items], waiting}
        {:waits, wait}, {items, waiting} -> {items, [wait | waiting]}
        :none, acc -> acc
      end)

    Enum.sort_by(items, & &1.object.id) ++ factory_items(namespace, waiting)
  end

  @doc """
  The factories whose runners decide what `rows` need: those of relays in a
  runner-bound state. What a caller reads before `derive/1`.
  """
  def waiting_factories(rows) do
    for row <- rows,
        NodeManager.row_health(row) in RelayState.runner_bound_states(),
        factory = row[:factory],
        factory != nil,
        uniq: true,
        do: to_string(factory)
  end

  defp relay_item(namespace, row, faulted, serving) do
    id = to_string(row.id)
    factory = row[:factory] && to_string(row.factory)
    count = factory && Map.get(serving, factory)
    state = relay_state(row, faulted)

    waits_on_runner? = count == 0 and state in RelayState.runner_bound_states()

    case RelayState.handled_by(state, count) do
      _you when waits_on_runner? ->
        {:waits, %{factory: factory, state: state}}

      handler when handler in [:flezha, :you] ->
        {:item, relay(namespace, id, state, handler, row, factory, count)}

      _nobody ->
        :none
    end
  end

  defp relay_state(row, faulted) do
    health = NodeManager.row_health(row)
    group = row[:partition] && row.partition.group

    cond do
      health != :healthy -> health
      is_nil(row[:node]) -> :unplaced
      group && group in faulted -> :coverage
      true -> :healthy
    end
  end

  defp relay(namespace, id, state, handler, row, factory, serving) do
    %{
      id: "relay:#{namespace}:#{id}",
      kind: :relay,
      reason: state,
      severity: Words.tone(:handled_by, handler),
      namespace: namespace,
      object: %{kind: :relay, id: id},
      what: relay_what(id, state, row),
      relay: %{state: state, factory: factory, serving: serving},
      actions: [
        %{
          label: "Diagnose",
          do: :diagnose,
          operation: "Relay.diagnose",
          namespace: namespace,
          relay: id
        },
        %{label: "Open relay", navigate: ~p"/namespaces/#{namespace}/relays/#{id}"}
      ],
      first_seen: nil
    }
  end

  defp relay_what(id, :unplaced, _row), do: "#{id} is unplaced"

  defp relay_what(id, :coverage, row),
    do: "#{id} owns a broken key range in partition group #{row.partition.group}"

  defp relay_what(id, state, _row), do: "#{id} is #{RelayState.word(state)}"

  defp factory_items(namespace, waiting) do
    waiting
    |> Enum.group_by(& &1.factory, & &1.state)
    |> Enum.sort()
    |> Enum.map(fn {factory, states} ->
      problem(
        :factory,
        %{
          id: "factory:#{namespace}:#{factory}",
          reason: :no_runner,
          namespace: namespace,
          object: %{kind: :factory, id: factory},
          what: "No runner serves factory #{factory}",
          actions: [%{label: "Open cluster", navigate: ~p"/cluster"}]
        },
        cause: "0 runners serve #{factory}",
        impact: waiting_words(states),
        handled_by: :you,
        next: "Start a runner that serves #{factory}"
      )
    end)
  end

  # "3 relays wait: 2 suspended, 1 unbound", states in rank order.
  defp waiting_words(states) do
    counts = Enum.frequencies(states)

    by_state =
      for state <- NodeManager.health_verdicts(),
          count = Map.get(counts, state),
          do: "#{count} #{RelayState.word(state)}"

    verb = if length(states) == 1, do: "waits", else: "wait"
    "#{Words.count(length(states), "relay")} #{verb}: #{Enum.join(by_state, ", ")}"
  end

  # An item that is not a relay: its State is its kind's word, and its tone
  # follows who handles it, red for the operator and amber for Flezha.
  defp problem(kind, fields, condition) do
    handler = Keyword.fetch!(condition, :handled_by)

    Map.merge(
      %{
        kind: kind,
        severity: Words.tone(:handled_by, handler),
        namespace: nil,
        condition: %{
          state: Words.say(:problem, kind),
          cause: Keyword.fetch!(condition, :cause),
          impact: Keyword.fetch!(condition, :impact),
          handled: RelayState.handler_said(handler),
          next: Keyword.fetch!(condition, :next)
        },
        first_seen: nil
      },
      fields
    )
  end

  defp group_items(namespace, groups) do
    for group <- groups do
      problem(
        :partition_group,
        %{
          id: "group:#{namespace}:#{group}",
          reason: :coverage,
          namespace: namespace,
          object: %{kind: :partition_group, id: to_string(group)},
          what: "Partition group #{group} has broken coverage",
          actions: [%{label: "Open namespace", navigate: ~p"/namespaces/#{namespace}"}]
        },
        cause: "Members leave key groups uncovered or overlapping",
        impact: "Traffic for those key groups is lost",
        handled_by: :you,
        next: "Fix the members' key ranges"
      )
    end
  end

  defp quota_items(namespace, quotas) do
    for %{breached?: true} = row <- quotas do
      kind = Words.humanize(row.kind) |> String.downcase()

      problem(
        :quota,
        %{
          id: "quota:#{namespace}:#{row.kind}",
          reason: :breached,
          namespace: namespace,
          object: %{kind: :quota, id: to_string(row.kind)},
          what: "#{namespace} reached its #{kind} limit",
          actions: [%{label: "Open limits", navigate: ~p"/namespaces/#{namespace}" <> "#quotas"}]
        },
        cause: "#{row.value} of #{row.limit} #{kind} in use",
        impact: "Another is refused",
        handled_by: :you,
        next: "Free one or raise the limit"
      )
    end
  end

  defp dead_letter_items(stats) do
    stats
    |> Enum.group_by(&to_string(Map.get(&1, :relay_class)))
    |> Enum.flat_map(fn {class, rows} ->
      entries = Enum.reduce(rows, 0, &(&2 + (Map.get(&1, :entries) || 0)))
      tasklets = rows |> Enum.map(&to_string(Map.get(&1, :tasklet_id))) |> Enum.uniq()

      if entries > 0 do
        [
          problem(
            :dead_letters,
            %{
              id: "dead_letters:#{class}",
              reason: :entries,
              object: %{kind: :relay_class, id: class},
              what: "#{Words.count(entries, "dead letter")} for #{class}",
              actions: [%{label: "Open dead-letter", navigate: ~p"/dlq?#{[class: class]}"}]
            },
            cause:
              "#{tasklet_phrase(tasklets)} could not process #{Words.count(entries, "record")}",
            impact: "They wait in the dead-letter queue",
            handled_by: :you,
            next: "Replay or drop them"
          )
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.object.id)
  end

  defp tasklet_phrase([one]), do: "Tasklet #{one}"
  defp tasklet_phrase(many), do: "Tasklets #{Words.join(many)}"

  defp rpo_items([]), do: []

  defp rpo_items(breaches) do
    count = Words.count(length(breaches), "reference")

    [
      problem(
        :rpo,
        %{
          id: "rpo",
          reason: :breached,
          object: %{kind: :controller, id: "durability"},
          what: "#{count} past their RPO target",
          actions: [%{label: "Open controller", navigate: ~p"/controller"}]
        },
        cause: "#{count} not shipped within the RPO target",
        impact: "Their state has one copy",
        handled_by: :flezha,
        next: "Shipped by the remote tier"
      )
    ]
  end

  defp stall_items([]), do: []

  defp stall_items([verdict | _older]) do
    subject = verdict[:subject]
    layer = Words.humanize(verdict[:layer]) |> String.downcase()
    on = if(subject, do: " on #{subject}", else: "")

    [
      problem(
        :stall,
        %{
          id: "stall:#{verdict[:layer]}:#{subject}",
          reason: :stalled,
          object: %{kind: :stall, id: subject || to_string(verdict[:layer])},
          what: "A stall was localized at the #{layer}" <> on,
          actions: [%{label: "Open cluster", navigate: ~p"/cluster"}]
        },
        cause: "Localized at the #{layer}" <> on,
        impact: "Records stop moving there",
        handled_by: :flezha,
        next: "Cleared when records move again"
      )
    ]
  end

  defp bootstrap_items(%{posture: :bootstrap_pending}) do
    [
      problem(
        :bootstrap,
        %{
          id: "bootstrap",
          reason: :unclaimed,
          object: %{kind: :controller, id: "authorization"},
          what: "Authorization is enforced but not claimed",
          actions: [%{label: "Open controller", navigate: ~p"/controller"}]
        },
        cause: "No admin claimed authorization",
        impact: "Every operator verb is refused",
        handled_by: :you,
        next: "Run flz auth bootstrap"
      )
    ]
  end

  defp bootstrap_items(_authz), do: []

  defp skew_items({:api_missing, module, function, arity}) do
    call = "#{inspect(module)}.#{function}/#{arity}"

    [
      problem(
        :skew,
        %{
          id: "skew",
          reason: :api_missing,
          object: %{kind: :controller, id: "version"},
          what: "The console and the controller disagree on versions",
          actions: [%{label: "Open cluster", navigate: ~p"/cluster"}]
        },
        cause: "The controller lacks #{call}",
        impact: "Screens that need it fail",
        handled_by: :you,
        next: "Run matching console and controller versions"
      )
    ]
  end

  defp skew_items(_skew), do: []

  @doc """
  Carries each item's `first_seen` over from `seen`, the items of the last
  read keyed by id, stamping new ones with `now`. Answers
  `{items, appeared, cleared}`: the items in order, and what came and went
  since the last read.
  """
  def track(seen, items, now) do
    tracked = Enum.map(items, &%{&1 | first_seen: (seen[&1.id] || %{first_seen: now}).first_seen})
    ids = MapSet.new(items, & &1.id)

    {order(tracked), Enum.reject(tracked, &Map.has_key?(seen, &1.id)),
     seen |> Map.values() |> Enum.reject(&MapSet.member?(ids, &1.id)) |> order()}
  end

  @doc "Items keyed by id: what `track/3` reads as the last read."
  def by_id(items), do: Map.new(items, &{&1.id, &1})

  @doc "Worst first, then the longest seen, then by id."
  def order(items) do
    Enum.sort_by(items, fn item ->
      {if(item.severity == :negative, do: 0, else: 1), sort_time(item.first_seen), item.id}
    end)
  end

  defp sort_time(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp sort_time(_none), do: 0

  @doc "The tone of the worst item: `:negative`, `:warning`, or `nil` for none."
  def worst([]), do: nil

  def worst(items),
    do: if(Enum.any?(items, &(&1.severity == :negative)), do: :negative, else: :warning)

  # ---- Rendering ----

  @doc """
  Attention items, each with what is wrong, its condition rows, where, how
  long it has been seen, and its actions as buttons — only those the operator's operations
  allow. A relay item reads as its `FlezhaUiWeb.RelayState.summary/1`, where
  Diagnose answers inline.

  `limit` shows the first items and a link to the rest on the Open problems
  screen.
  """
  attr :items, :list, required: true
  attr :operations, :any, required: true
  attr :diagnoses, :map, default: %{}
  attr :limit, :integer, default: nil
  attr :now, :any, default: nil
  attr :testid, :string, default: "problems"

  def problem_list(assigns) do
    shown = if assigns.limit, do: Enum.take(assigns.items, assigns.limit), else: assigns.items

    assigns =
      assign(assigns,
        shown: shown,
        more: length(assigns.items) - length(shown),
        now: assigns.now || DateTime.utc_now()
      )

    ~H"""
    <div data-testid={@testid} class="space-y-3">
      <ul class="fui-problems">
        <li
          :for={item <- @shown}
          class={["fui-problem", item.severity == :negative && "fui-problem--negative"]}
          data-testid={"problem-#{item.id}"}
          data-severity={item.severity}
        >
          <p class="fui-problem-what">
            <span
              class={"fui-shape fui-tone-#{item.severity}"}
              data-shape={Words.shape(item.severity)}
              aria-hidden="true"
            >
            </span>
            {item.what}
          </p>
          <RelayState.summary
            :if={item[:relay]}
            state={item.relay.state}
            factory={item.relay.factory}
            serving={item.relay.serving}
            diagnosis={@diagnoses[item.id] && @diagnoses[item.id].diagnosis}
            error={@diagnoses[item.id] && @diagnoses[item.id].error}
            testid={"problem-state-#{item.id}"}
            diagnosis_testid={"problem-diagnosis-#{item.id}"}
          />
          <.condition :if={!item[:relay]} facts={item.condition} testid={"problem-state-#{item.id}"} />
          <p class="fui-problem-meta">
            {[item.namespace, object_words(item.object), seen(item.first_seen, @now)]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" · ")}
          </p>
          <div class="fui-problem-actions">
            <%= for action <- item.actions, allowed?(action, @operations) do %>
              <.button
                :if={action[:do] == :diagnose}
                variant="secondary"
                size="sm"
                phx-click="problem_diagnose"
                phx-value-namespace={action.namespace}
                phx-value-relay={action.relay}
                phx-value-item={item.id}
                data-testid={"problem-diagnose-#{item.id}"}
              >
                {action.label}
              </.button>
              <.button
                :if={action[:navigate]}
                variant="ghost"
                size="sm"
                navigate={action.navigate}
                data-testid={"problem-open-#{item.id}"}
              >
                {action.label}
              </.button>
            <% end %>
          </div>
        </li>
      </ul>
      <.link :if={@more > 0} navigate={~p"/problems"} data-testid="problems-more">
        {Words.count(@more, "more problem")} on the Open problems screen
      </.link>
    </div>
    """
  end

  defp allowed?(%{operation: operation}, operations),
    do: NodeManager.granted?(operations, operation)

  defp allowed?(_action, _operations), do: true

  defp object_words(%{kind: :relay, id: id}), do: "relay #{id}"
  defp object_words(%{kind: :partition_group, id: id}), do: "partition group #{id}"
  defp object_words(%{kind: :quota, id: id}), do: "quota #{id}"
  defp object_words(%{kind: :relay_class, id: id}), do: "relay class #{id}"
  defp object_words(%{kind: :factory, id: id}), do: "factory #{id}"
  defp object_words(%{kind: :stall}), do: nil
  defp object_words(%{kind: :controller}), do: "the controller"
  defp object_words(_object), do: nil

  defp seen(%DateTime{} = at, now) do
    case DateTime.diff(now, at) do
      seconds when seconds < 5 -> "seen just now"
      seconds -> "seen for #{Format.age(seconds)}"
    end
  end

  defp seen(_none, _now), do: nil
end
