defmodule FlezhaConsoleWeb.Attention do
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
  Flezha. Dead letters are a warning whoever handles them, and name the
  namespace whose relay rows hold their class. A relay item carries
  `relay: %{state:, factory:, serving:}` in place of `condition`, which
  `FlezhaConsoleWeb.RelayState.summary/1` renders with the diagnosis once
  asked; `serving` is how many runners serve its factory, nil when unread. It
  names no runner: a registry row names the one that last hosted the relay,
  not the one bound to it now, which only the relay's own Overwatch reads.

  and an action is `%{label:, navigate:}`, `%{label:, do: :diagnose,
  operation:, namespace:, relay:}` or `%{label:, grow: listing, shown:,
  step:}`, which grows a listing's read as `grid_more` does; `operation`
  names the controller verb that gates it. `first_seen` is when this console first saw the item, kept across
  reads by `track/3`.
  """

  use FlezhaConsoleWeb, :html

  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.Live.Sections
  alias FlezhaConsoleWeb.RelayState

  # How many of a namespace's relays the items are read from at first: the
  # most severe, unhealthy or suspended.
  @read 50

  # Named exactly, so a host's own events cannot be swallowed.
  @events ~w(problem_diagnose)

  @doc """
  Embeds the problem list in a host LiveView: the inline diagnosis its
  Diagnose action answers. The host calls `attention_init/1` in mount.
  """
  defmacro __using__(_opts) do
    events = @events

    quote do
      import FlezhaConsoleWeb.Attention, only: [attention_init: 1, problem_list: 1]

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) when event in unquote(events) do
        {:noreply, FlezhaConsoleWeb.Attention.handle_event(event, params, socket)}
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

    * `:namespaces` — `[%{namespace:, page:, quotas:, serving:, owns:}]`,
      `page` the namespace's most severe relays as `page/1` keeps them,
      `serving` mapping each factory `waiting_factories/1` names to how many
      runners serve it, and `owns` the ids of its relays that dead-letter
      classes name;
    * `:dlq` — the dead-letter statistics, each class's items placed in the
      namespace that `owns` that relay; a row's `:seen` entries, as
      `FlezhaConsole.DeadLetters.stats/1` counts them, are no problem;
    * `:breaches` — references past their RPO target;
    * `:verdicts` — recent stall verdicts, as `FlezhaConsoleWeb.Topology.stall/1` answers;
    * `:authz` — the `NodeManager.authz_status/1` map;
    * `:skew` — an `{:api_missing, module, function, arity}` a read answered.
  """
  def derive(input) do
    namespaced =
      Enum.flat_map(Map.get(input, :namespaces, []), fn ns ->
        page = Map.get(ns, :page, page(nil))

        relay_items(ns.namespace, page, Map.get(ns, :serving, %{})) ++
          group_items(ns.namespace, broken_groups(page)) ++
          quota_items(ns.namespace, Map.get(ns, :quotas, []))
      end)

    namespaced ++
      dead_letter_items(Map.get(input, :dlq, []), relay_namespaces(input)) ++
      rpo_items(Map.get(input, :breaches, [])) ++
      stall_items(Map.get(input, :verdicts, [])) ++
      bootstrap_items(Map.get(input, :authz)) ++
      skew_items(Map.get(input, :skew))
  end

  @doc """
  The controller `opts` reading the relays a namespace's items come from:
  the `shown` most severe that are unhealthy or suspended, with the
  namespace's summary.
  """
  def relay_opts(shown \\ @read),
    do: [limit: shown, sort: :severity, filter: [health: ["unhealthy", "suspended"]]]

  # The listing a namespace's items are read as, grown by the item saying how
  # many more relays are not healthy; screens match its `problems-` prefix.
  defp listing(namespace), do: "problems-#{namespace}"

  @doc "How many of `namespace`'s relays the items are read from, as `paging` has grown it."
  def shown(paging, namespace), do: Sections.limit(paging, listing(namespace), @read)

  @doc """
  A namespace's relay read as the items take it, `%{rows:, read:, total:,
  summary:, health:, relay_count:}`: its rows with each partition group's
  members in place of the group, how many rows were read of how many, the
  namespace's summary, its relays by health as `NodeManager.health_pairs/1`
  pairs and how many there are; nothing for a read that failed.
  """
  def page({:ok, %{rows: rows} = page}) do
    summary = Map.get(page, :summary) || %{}
    counted = Map.get(summary, :health, %{})

    %{
      rows: Enum.flat_map(rows, &(&1[:members] || [&1])),
      read: length(rows),
      total: Map.get(page, :total, length(rows)),
      summary: summary,
      health: NodeManager.health_pairs(counted),
      relay_count: counted |> Map.values() |> Enum.sum()
    }
  end

  def page(_failed), do: %{rows: [], read: 0, total: 0, summary: %{}, health: [], relay_count: 0}

  @doc """
  The items for a namespace's relays, from `page/1`'s page: each relay whose
  condition Flezha or the operator handles — surfaced whatever its
  throughput, since a stuck relay is exactly the one whose counters stopped
  moving — one item per factory no runner serves, holding every relay that
  waits only on it, and one stating how many more relays are not healthy
  than were read.

  `serving` maps a factory to how many runners serve it; a factory it does
  not hold is unread, and a suspended relay of an unread factory is no item.
  """
  def relay_items(namespace, page, serving \\ %{}) do
    broken = page |> broken_groups() |> MapSet.new()

    {items, waiting} =
      page.rows
      |> Enum.map(&relay_item(namespace, &1, broken, serving))
      |> Enum.reduce({[], []}, fn
        {:item, item}, {items, waiting} -> {[item | items], waiting}
        {:waits, wait}, {items, waiting} -> {items, [wait | waiting]}
        :none, acc -> acc
      end)

    waiting_counts = waiting_counts(page, serving)

    Enum.sort_by(items, & &1.object.id) ++
      factory_items(namespace, waiting, waiting_counts) ++
      unread_items(namespace, page, waiting, waiting_counts)
  end

  # The groups whose key-group coverage the summary says is not whole.
  defp broken_groups(page) do
    for %{group: group, complete: false} <- Map.get(page.summary, :faulted_groups, []),
        do: to_string(group)
  end

  # How many relays wait on each factory no runner serves, across the
  # namespace, as the summary counts them.
  defp waiting_counts(page, serving) do
    for %{factory: factory, relays: count} <- Map.get(page.summary, :waiting, []),
        Map.get(serving, to_string(factory)) == 0,
        into: %{},
        do: {to_string(factory), count}
  end

  @doc """
  The factories whose runners decide what a namespace's `page/1` page needs:
  those of relays in a runner-bound state, and those the summary says relays
  wait on. What a caller reads before `derive/1`.
  """
  def waiting_factories(page) do
    from_rows =
      for row <- page.rows,
          NodeManager.row_health(row) in RelayState.runner_bound_states(),
          factory = row[:factory],
          factory != nil,
          do: to_string(factory)

    from_summary =
      for %{factory: factory} <- Map.get(page.summary, :waiting, []), do: to_string(factory)

    Enum.uniq(from_rows ++ from_summary)
  end

  @doc """
  `fresh` serving counts, keeping the last `known` count of a waiting factory
  whose read failed, so one failed read does not regroup its relays.
  """
  def keep_serving(fresh, known, factories),
    do: (known || %{}) |> Map.take(factories) |> Map.merge(fresh)

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

  # A factory's waiting relays are those read and, from the summary, those
  # unbound or recovering beyond them; a factory none of the read relays
  # names still has its item.
  defp factory_items(namespace, waiting, counts) do
    read = Enum.group_by(waiting, & &1.factory, & &1.state)

    counts
    |> Map.keys()
    |> Enum.concat(Map.keys(read))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn factory ->
      states = Map.get(read, factory, [])

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
        impact: waiting_words(states, waiting_total(states, Map.get(counts, factory, 0))),
        handled_by: :you,
        next: "Start a runner that serves #{factory}"
      )
    end)
  end

  # The relays read waiting on a factory, with those the summary counts
  # unbound or recovering past them.
  defp waiting_total(states, summarised) do
    read = Enum.count(states, &(&1 in [:unbound, :recovering]))
    length(states) - read + max(summarised, read)
  end

  # "3 relays wait: 2 suspended, 1 unbound", states in rank order, when every
  # one was read; "950 relays wait for a runner" when not.
  defp waiting_words(states, total) when total > length(states),
    do: "#{Words.count(total, "relay")} wait for a runner"

  defp waiting_words(states, _total) do
    counts = Enum.frequencies(states)

    by_state =
      for state <- NodeManager.health_verdicts(),
          count = Map.get(counts, state),
          do: "#{count} #{RelayState.word(state)}"

    verb = if length(states) == 1, do: "waits", else: "wait"
    "#{Words.count(length(states), "relay")} #{verb}: #{Enum.join(by_state, ", ")}"
  end

  # The relays not read, less those a factory item already counts.
  defp unread_items(namespace, page, waiting, counts) do
    read_waiting =
      Enum.frequencies_by(
        Enum.filter(waiting, &(&1.state in [:unbound, :recovering])),
        & &1.factory
      )

    folded =
      counts
      |> Enum.map(fn {factory, count} -> max(count - Map.get(read_waiting, factory, 0), 0) end)
      |> Enum.sum()

    case page.total - page.read - folded do
      more when more > 0 ->
        [
          problem(
            :unread,
            %{
              id: "unread:#{namespace}",
              reason: :unread,
              namespace: namespace,
              object: %{kind: :namespace, id: namespace},
              what:
                "#{Words.count(more, "more relay")} in #{namespace} #{if more == 1, do: "is", else: "are"} not healthy",
              actions: [
                %{label: "Show more", grow: listing(namespace), shown: page.read, step: @read},
                %{
                  label: "Open relays",
                  navigate: ~p"/namespaces/#{namespace}/relays?#{[sort: "severity"]}"
                }
              ]
            },
            cause: "Only the #{page.read} most severe are read at once",
            impact: "They are listed on the relays screen, most severe first",
            handled_by: :you,
            next: "Show more, or open the relays"
          )
        ]

      _none ->
        []
    end
  end

  # An item that is not a relay: its State is its kind's word, whose tone is
  # the item's severity.
  defp problem(kind, fields, condition) do
    state = Words.say(:problem, kind)

    Map.merge(
      %{
        kind: kind,
        severity: state.tone,
        namespace: nil,
        condition: %{
          state: state,
          cause: Keyword.fetch!(condition, :cause),
          impact: Keyword.fetch!(condition, :impact),
          handled: RelayState.handler_said(Keyword.fetch!(condition, :handled_by)),
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

  # A relay class is its relay's id, so the namespace that owns that relay
  # owns the class's dead letters.
  defp relay_namespaces(input) do
    for ns <- Map.get(input, :namespaces, []),
        id <- Map.get(ns, :owns, []),
        into: %{},
        do: {to_string(id), ns.namespace}
  end

  defp dead_letter_items(stats, namespaces) do
    stats
    |> Enum.group_by(&to_string(Map.get(&1, :relay_class)))
    |> Enum.flat_map(fn {class, rows} ->
      rows = Enum.filter(rows, &(unseen(&1) > 0))
      entries = rows |> Enum.map(&unseen/1) |> Enum.sum()
      tasklets = rows |> Enum.map(&to_string(Map.get(&1, :tasklet_id))) |> Enum.uniq()

      if entries > 0 do
        [
          problem(
            :dead_letters,
            %{
              id: "dead_letters:#{class}",
              reason: :entries,
              namespace: Map.get(namespaces, class),
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

  defp unseen(row), do: (Map.get(row, :entries) || 0) - (Map.get(row, :seen) || 0)

  @doc "The dead-letter stats rows holding entries no operator has marked seen: those that are items."
  def unseen_stats(stats), do: Enum.filter(stats, &(unseen(&1) > 0))

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
  allow. A relay item reads as its `FlezhaConsoleWeb.RelayState.summary/1`, where
  Diagnose answers inline.

  `limit` shows the first items and a link to the rest on the Open problems
  screen; `paging` instead shows them a page at a time.
  """
  attr :items, :list, required: true
  attr :operations, :any, required: true
  attr :diagnoses, :map, default: %{}
  attr :limit, :integer, default: nil
  attr :paging, :map, default: nil, doc: "the screen's `@paging`, to page the items"
  attr :now, :any, default: nil
  attr :testid, :string, default: "problems"

  def problem_list(assigns) do
    limit = assigns.limit || (assigns.paging && Sections.shown(assigns.paging, assigns.testid))
    shown = if limit, do: Enum.take(assigns.items, limit), else: assigns.items

    assigns =
      assign(assigns,
        shown: shown,
        more: length(assigns.items) - length(shown),
        now: assigns.now || DateTime.utc_now()
      )

    ~H"""
    <div data-testid={@testid} class="space-y-3">
      <ul class="fcon-problems">
        <li
          :for={item <- @shown}
          class={["fcon-problem", item.severity == :negative && "fcon-problem--negative"]}
          data-testid={"problem-#{item.id}"}
          data-severity={item.severity}
        >
          <p class="fcon-problem-what">
            <span
              class={"fcon-shape fcon-tone-#{item.severity}"}
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
          <p class="fcon-problem-meta">
            {[item.namespace, object_words(item.object), seen(item.first_seen, @now)]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" · ")}
          </p>
          <div class="fcon-problem-actions">
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
                :if={action[:grow]}
                variant="secondary"
                size="sm"
                phx-click="grid_more"
                phx-value-id={action.grow}
                phx-value-shown={action.shown}
                phx-value-step={action.step}
                data-testid={"problem-grow-#{item.id}"}
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
      <.more
        :if={@paging}
        id={@testid}
        shown={length(@shown)}
        total={length(@items)}
      />
      <.link :if={!@paging and @more > 0} navigate={~p"/problems"} data-testid="problems-more">
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
