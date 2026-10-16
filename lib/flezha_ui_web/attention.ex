defmodule FlezhaUiWeb.Attention do
  @moduledoc """
  The console's open problems, derived in one place from reads it already
  makes.

  Pure: `derive/1` takes what the controller answered and answers attention
  items, each saying what is wrong, why — built from the read that found it —
  and the actions that address it. Home lists its namespace's items, the
  shell's pulse counts them for every reachable namespace, and `/problems`
  lists them all; `FlezhaUiWeb.Topology.summary/1` takes its attention list
  from here too.

  An item is

      %{id:, kind:, severity: :warning | :negative, namespace:, object: %{kind:, id:},
        what:, why:, actions: [action], first_seen:}

  and an action is `%{label:, navigate:}` or `%{label:, do: :diagnose,
  operation:, namespace:, relay:}`; `operation` names the controller verb that
  gates it. `first_seen` is when this console first saw the item, kept across
  reads by `track/3`.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager

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

    * `:namespaces` — `[%{namespace:, rows:, faulted_groups:, quotas:}]`;
    * `:dlq` — the dead-letter statistics;
    * `:breaches` — references past their RPO target;
    * `:verdicts` — recent stall verdicts, as `FlezhaUiWeb.Topology.stall/1` answers;
    * `:authz` — the `NodeManager.authz_status/1` map;
    * `:skew` — an `{:api_missing, module, function, arity}` a read answered.
  """
  def derive(input) do
    namespaced =
      Enum.flat_map(Map.get(input, :namespaces, []), fn ns ->
        relay_items(ns.namespace, Map.get(ns, :rows, []), Map.get(ns, :faulted_groups, [])) ++
          group_items(ns.namespace, Map.get(ns, :faulted_groups, [])) ++
          quota_items(ns.namespace, Map.get(ns, :quotas, []))
      end)

    namespaced ++
      parked_items(Map.get(input, :dlq, [])) ++
      rpo_items(Map.get(input, :breaches, [])) ++
      stall_items(Map.get(input, :verdicts, [])) ++
      bootstrap_items(Map.get(input, :authz)) ++
      skew_items(Map.get(input, :skew))
  end

  @doc """
  The items for a namespace's relays: each relay that is not healthy, has no
  live node, or belongs to a partition group whose coverage is faulted —
  surfaced whatever its throughput, since a stuck relay is exactly the one
  whose counters stopped moving.
  """
  def relay_items(namespace, rows, faulted_groups \\ []) do
    rows
    |> Enum.flat_map(&relay_item(namespace, &1, faulted_groups))
    |> Enum.sort_by(& &1.object.id)
  end

  defp relay_item(namespace, row, faulted) do
    id = to_string(row.id)
    health = NodeManager.row_health(row)
    group = row[:partition] && row.partition.group

    cond do
      health != :healthy ->
        [
          relay(
            namespace,
            id,
            health,
            severity(health),
            "#{id} is #{health_word(health)}",
            why(health)
          )
        ]

      is_nil(row[:node]) ->
        [
          relay(
            namespace,
            id,
            :unplaced,
            :warning,
            "#{id} is unplaced",
            "The registry holds it, but no live cluster node runs it."
          )
        ]

      group && group in faulted ->
        [
          relay(
            namespace,
            id,
            :coverage,
            :negative,
            "#{id} owns a broken key range",
            "Its partition group #{group} does not cover every key group exactly once."
          )
        ]

      true ->
        []
    end
  end

  defp relay(namespace, id, reason, severity, what, why) do
    %{
      id: "relay:#{namespace}:#{id}",
      kind: :relay,
      reason: reason,
      severity: severity,
      namespace: namespace,
      object: %{kind: :relay, id: id},
      what: what,
      why: why,
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

  defp health_word(health), do: String.downcase(Words.text(:health, health))

  defp severity(health) when health in [:failed, :parked], do: :negative
  defp severity(_health), do: :warning

  defp why(:suspended),
    do:
      "The controller reports it suspended: parked at a committed boundary with no runner to resume on."

  defp why(:unbound), do: "No runner serves its factory, so it is waiting for one to connect."

  defp why(:degraded),
    do: "The Convergence Loop classifies it degraded: it runs, but not as declared."

  defp why(:recovering), do: "The controller is moving it off a runner that went away."
  defp why(:failed), do: "The Convergence Loop classifies it failed: it is not running."
  defp why(:parked), do: "It is parked and processes no input until it is resumed."
  defp why(:unknown), do: "The Convergence Loop has not observed it yet."
  defp why(health), do: "The Convergence Loop reports it #{health_word(health)}."

  defp group_items(namespace, groups) do
    for group <- groups do
      %{
        id: "group:#{namespace}:#{group}",
        kind: :partition_group,
        reason: :coverage,
        severity: :negative,
        namespace: namespace,
        object: %{kind: :partition_group, id: to_string(group)},
        what: "Partition group #{group} has broken coverage",
        why:
          "Its members do not own every key group exactly once, so traffic for the uncovered key groups is lost.",
        actions: [%{label: "Open namespace", navigate: ~p"/namespaces/#{namespace}"}],
        first_seen: nil
      }
    end
  end

  defp quota_items(namespace, quotas) do
    for %{breached?: true} = row <- quotas do
      kind = Words.humanize(row.kind) |> String.downcase()

      %{
        id: "quota:#{namespace}:#{row.kind}",
        kind: :quota,
        reason: :breached,
        severity: :negative,
        namespace: namespace,
        object: %{kind: :quota, id: to_string(row.kind)},
        what: "#{namespace} reached its #{kind} limit",
        why:
          "#{row.value} of #{row.limit} are in use, so the controller refuses another until one is freed or the limit is raised.",
        actions: [%{label: "Open limits", navigate: ~p"/namespaces/#{namespace}" <> "#quotas"}],
        first_seen: nil
      }
    end
  end

  defp parked_items(stats) do
    stats
    |> Enum.group_by(&to_string(Map.get(&1, :relay_class)))
    |> Enum.flat_map(fn {class, rows} ->
      entries = Enum.reduce(rows, 0, &(&2 + (Map.get(&1, :entries) || 0)))
      tasklets = rows |> Enum.map(&to_string(Map.get(&1, :tasklet_id))) |> Enum.uniq()

      if entries > 0 do
        [
          %{
            id: "parked:#{class}",
            kind: :parked,
            reason: :entries,
            severity: :warning,
            namespace: nil,
            object: %{kind: :relay_class, id: class},
            what: "#{Words.count(entries, "entry", "entries")} parked for #{class}",
            why:
              "#{tasklet_phrase(tasklets)} could not process them, so they wait in the dead-letter queue to be replayed or dropped.",
            actions: [%{label: "Open dead-letter", navigate: ~p"/dlq?#{[class: class]}"}],
            first_seen: nil
          }
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
    [
      %{
        id: "rpo",
        kind: :rpo,
        reason: :breached,
        severity: :negative,
        namespace: nil,
        object: %{kind: :controller, id: "durability"},
        what: "#{Words.count(length(breaches), "reference")} past their RPO target",
        why:
          "The remote tier has not shipped them within the target, so the state behind them has one copy.",
        actions: [%{label: "Open controller", navigate: ~p"/controller"}],
        first_seen: nil
      }
    ]
  end

  defp stall_items([]), do: []

  defp stall_items([verdict | _older]) do
    subject = verdict[:subject]
    layer = Words.humanize(verdict[:layer]) |> String.downcase()

    [
      %{
        id: "stall:#{verdict[:layer]}:#{subject}",
        kind: :stall,
        reason: :stalled,
        severity: :warning,
        namespace: nil,
        object: %{kind: :stall, id: subject || to_string(verdict[:layer])},
        what:
          "A stall was localized at the #{layer}" <> if(subject, do: " on #{subject}", else: ""),
        why: "The health classifier flagged it within the last minute.",
        actions: [%{label: "Open cluster", navigate: ~p"/cluster"}],
        first_seen: nil
      }
    ]
  end

  defp bootstrap_items(%{posture: :bootstrap_pending}) do
    [
      %{
        id: "bootstrap",
        kind: :bootstrap,
        reason: :unclaimed,
        severity: :negative,
        namespace: nil,
        object: %{kind: :controller, id: "authorization"},
        what: "Authorization is enforced but not claimed",
        why:
          "No admin has claimed it with flz auth bootstrap, so the controller refuses every operator verb.",
        actions: [%{label: "Open controller", navigate: ~p"/controller"}],
        first_seen: nil
      }
    ]
  end

  defp bootstrap_items(_authz), do: []

  defp skew_items({:api_missing, module, function, arity}) do
    call = "#{inspect(module)}.#{function}/#{arity}"

    [
      %{
        id: "skew",
        kind: :skew,
        reason: :api_missing,
        severity: :warning,
        namespace: nil,
        object: %{kind: :controller, id: "version"},
        what: "The console and the controller disagree on versions",
        why: "The controller does not export #{call}, which this console calls.",
        actions: [%{label: "Open cluster", navigate: ~p"/cluster"}],
        first_seen: nil
      }
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
  Attention items, each with what is wrong, why, where, how long it has been
  seen, and its actions as buttons — only those the operator's operations
  allow. Diagnose answers inline beneath its item.

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
          <p class="fui-problem-why" data-testid={"problem-why-#{item.id}"}>{item.why}</p>
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
          <div :if={@diagnoses[item.id]} class="fui-problem-detail">
            <.diagnosis
              diagnosis={@diagnoses[item.id].diagnosis}
              error={@diagnoses[item.id].error}
              testid={"problem-diagnosis-#{item.id}"}
            />
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

  @doc """
  What the controller answered to Diagnose: its verdict in words and each
  finding, or why it could not be asked. One rendering for the relay screen,
  the relay inspector and a problem's inline answer.
  """
  attr :diagnosis, :map, default: nil
  attr :error, :any, default: nil
  attr :testid, :string, default: "diagnosis"

  def diagnosis(assigns) do
    ~H"""
    <div data-testid={@testid} class="space-y-3">
      <div :if={@error} data-testid="diagnose-error">
        <.runtime_error error={@error} action="the diagnosis" />
      </div>
      <p :if={@diagnosis}>
        <.state_badge kind={:diagnosis} value={@diagnosis.verdict} testid="diagnose-verdict" />
      </p>
      <p :if={@diagnosis && @diagnosis.findings == []}>The controller found nothing to report.</p>
      <ol :if={@diagnosis && @diagnosis.findings != []} class="space-y-2">
        <li
          :for={finding <- @diagnosis.findings}
          data-testid={"diagnose-finding-#{finding.code}"}
        >
          <.runtime_error error={finding} kind={if finding.level == :note, do: :info, else: :error} />
        </li>
      </ol>
    </div>
    """
  end
end
