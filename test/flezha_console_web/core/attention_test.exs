defmodule FlezhaConsoleWeb.AttentionTest do
  @moduledoc """
  The one derivation of open problems, fed the shapes the controller really
  answers: `relay_rows/2` rows, `quota_usage/3` rows, `Dlq.stats/1` rows,
  `durability_breaches/1`, stall verdicts and the authz status map.
  """

  use ExUnit.Case, async: true

  alias FlezhaConsoleWeb.Attention

  defp row(id, overrides \\ %{}) do
    Map.merge(
      %{id: id, health: :healthy, runner: "r1", factory: "f", partition: nil, node: :flezha@a},
      overrides
    )
  end

  defp text(item, key) do
    case item.condition[String.to_existing_atom(key)] do
      %{text: text} -> text
      other -> other
    end
  end

  test "a suspended relay a runner can wake is no problem, and one whose runners are unread neither" do
    rows = [row("testnet_echo", %{health: :suspended})]

    assert Attention.derive(%{
             namespaces: [%{namespace: "default", rows: rows, serving: %{"f" => 1}}]
           }) == []

    assert Attention.derive(%{namespaces: [%{namespace: "default", rows: rows}]}) == []
  end

  test "a failed serving read keeps the last known count of a factory that still waits" do
    rows = [row("a", %{health: :unbound}), row("b", %{health: :healthy, factory: "g"})]

    assert Attention.keep_serving(%{}, %{"f" => 0, "g" => 1, "gone" => 2}, rows) == %{"f" => 0}
    assert Attention.keep_serving(%{"f" => 3}, %{"f" => 0}, rows) == %{"f" => 3}
    assert Attention.keep_serving(%{}, nil, rows) == %{}
  end

  test "a failed relay Flezha is rebinding is a warning that offers Diagnose and Open relay" do
    [item] =
      Attention.derive(%{
        namespaces: [
          %{
            namespace: "default",
            rows: [row("orders", %{health: :failed})],
            serving: %{"f" => 2}
          }
        ]
      })

    assert item.what == "orders is failed"
    assert item.relay == %{state: :failed, factory: "f", serving: 2}
    assert item.severity == :warning
    assert item.namespace == "default"

    assert [
             %{label: "Diagnose", do: :diagnose, operation: "Relay.diagnose"},
             %{label: "Open relay"}
           ] = item.actions
  end

  # Every verdict but healthy and suspended is a problem whatever the runners;
  # the tone follows who handles it. A verdict this table misses fails the
  # coverage assertion rather than slipping through.
  @verdicts %{
    unknown: :warning,
    degraded: :warning,
    recovering: :warning,
    unbound: :warning,
    failed: :warning,
    halted: :negative
  }

  test "every health verdict a relay can be in is a problem toned by who handles it" do
    assert Enum.sort(Map.keys(@verdicts)) ==
             Enum.sort(
               FlezhaConsole.Service.NodeManager.health_verdicts() -- [:healthy, :suspended]
             )

    for {health, severity} <- @verdicts do
      assert [item] = Attention.relay_items("default", [row("r", %{health: health})]),
             "#{health} raised no item"

      assert {item.reason, item.severity} == {health, severity}
      assert item.what =~ ~r/^r is \S/
    end

    assert Attention.relay_items("default", [row("r")]) == []
  end

  test "relays that wait only on a missing runner fold into one item for their factory" do
    rows = [
      row("a", %{health: :suspended, factory: "echo_steps"}),
      row("b", %{health: :suspended, factory: "echo_steps"}),
      row("c", %{health: :unbound, factory: "echo_steps"}),
      row("h", %{health: :halted, factory: "echo_steps"}),
      row("d", %{health: :degraded, factory: "other"})
    ]

    items = Attention.relay_items("default", rows, [], %{"echo_steps" => 0, "other" => 1})
    by_id = Map.new(items, &{&1.id, &1})

    assert Map.keys(by_id) |> Enum.sort() ==
             ["factory:default:echo_steps", "relay:default:d", "relay:default:h"]

    factory = by_id["factory:default:echo_steps"]
    assert factory.what == "No runner serves factory echo_steps"
    assert factory.severity == :negative
    assert text(factory, "state") == "No runner"
    assert text(factory, "impact") == "3 relays wait: 2 suspended, 1 unbound"
    assert text(factory, "handled") == "You"
    assert text(factory, "next") == "Start a runner that serves echo_steps"
    assert [%{label: "Open cluster", navigate: "/cluster"}] = factory.actions

    assert by_id["relay:default:h"].severity == :negative
    assert by_id["relay:default:d"].severity == :warning
  end

  test "the factories read are those of relays in a runner-bound state" do
    rows = [
      row("s", %{health: :suspended}),
      row("u", %{health: :unbound, factory: "g"}),
      row("d", %{health: :degraded, factory: "h"}),
      row("ok", %{factory: "i"})
    ]

    assert Enum.sort(Attention.waiting_factories(rows)) == ["f", "g"]
    assert Attention.waiting_factories([row("ok")]) == []
  end

  test "a row with no health reads as unknown, never as healthy" do
    assert [%{reason: :unknown, severity: :warning}] =
             Attention.relay_items("default", [Map.delete(row("r"), :health)])
  end

  test "a halted relay is negative; an unplaced one and a faulted group are found too" do
    items =
      Attention.derive(%{
        namespaces: [
          %{
            namespace: "default",
            rows: [
              row("f", %{health: :halted}),
              row("u", %{node: nil}),
              row("m", %{partition: %{group: "g1", index: 0, count: 2, range: {0, 1}}})
            ],
            faulted_groups: ["g1"]
          }
        ]
      })

    by_object = Map.new(items, &{&1.object.id, &1})

    assert by_object["f"].severity == :negative
    assert by_object["u"].what == "u is unplaced"
    assert by_object["m"].what == "m owns a broken key range in partition group g1"
    assert by_object["m"].severity == :negative
    assert by_object["g1"].kind == :partition_group
    assert text(by_object["g1"], "state") == "Coverage broken"
  end

  test "a quota at its limit is negative and links to the namespace's limits" do
    [item] =
      Attention.derive(%{
        namespaces: [
          %{
            namespace: "default",
            rows: [],
            quotas: [
              %{kind: :relays, limit_key: :max_relays, value: 5, limit: 5, breached?: true}
            ]
          }
        ]
      })

    assert item.severity == :negative
    assert item.what == "default reached its relays limit"
    assert text(item, "cause") == "5 of 5 relays in use"
    assert text(item, "handled") == "You"
    assert [%{navigate: "/namespaces/default#quotas"}] = item.actions
  end

  test "dead letters name their class and count and link to the filtered dead-letter screen" do
    [item] =
      Attention.derive(%{
        dlq: [
          %{relay_class: "orders", tasklet_id: "t1", entries: 2},
          %{relay_class: "orders", tasklet_id: "t2", entries: 1},
          %{relay_class: "empty", tasklet_id: "t", entries: 0}
        ]
      })

    assert item.what == "3 dead letters for orders"
    assert item.severity == :warning
    assert item.namespace == nil
    assert text(item, "cause") == "Tasklets t1 and t2 could not process 3 records"
    assert text(item, "handled") == "You"
    assert text(item, "next") == "Replay or drop them"
    refute inspect(item) =~ "parked"
    assert [%{navigate: "/dlq?class=orders"}] = item.actions
  end

  test "seen dead letters are no problem, and only the unseen are counted" do
    [item] =
      Attention.derive(%{
        dlq: [
          %{relay_class: "orders", tasklet_id: "t1", entries: 2, seen: 1},
          %{relay_class: "orders", tasklet_id: "t2", entries: 1, seen: 1},
          %{relay_class: "prices", tasklet_id: "t", entries: 3, seen: 3}
        ]
      })

    assert item.what == "1 dead letter for orders"
    assert text(item, "cause") == "Tasklet t1 could not process 1 record"
  end

  test "dead letters belong to the namespace whose relay rows hold their class" do
    items =
      Attention.derive(%{
        namespaces: [
          %{namespace: "default", rows: [%{id: :orders, health: :healthy, node: :a}]},
          %{namespace: "sandbox", rows: [%{id: "prices", health: :healthy, node: :a}]}
        ],
        dlq: [
          %{relay_class: "orders", tasklet_id: "t", entries: 1},
          %{relay_class: "prices", tasklet_id: "t", entries: 2},
          %{relay_class: "stopped", tasklet_id: "t", entries: 3}
        ]
      })

    assert Map.new(items, &{&1.object.id, &1.namespace}) ==
             %{"orders" => "default", "prices" => "sandbox", "stopped" => nil}

    assert Enum.all?(items, &(&1.severity == :warning))
  end

  test "RPO breaches, a stall, an unclaimed bootstrap and version skew are each one item" do
    items =
      Attention.derive(%{
        breaches: [%{ref: :a}, %{ref: :b}],
        verdicts: [%{layer: :runner_channel, subject: "orders"}],
        authz: %{posture: :bootstrap_pending},
        skew: {:api_missing, Flezha.Service.Relay, :relay_rows, 2}
      })

    assert Enum.map(items, & &1.kind) == [:rpo, :stall, :bootstrap, :skew]
    assert Enum.map(items, & &1.severity) == [:warning, :warning, :negative, :negative]
    assert Enum.find(items, &(&1.kind == :rpo)).what == "2 references past their RPO target"

    assert text(Enum.find(items, &(&1.kind == :skew)), "cause") =~
             "Flezha.Service.Relay.relay_rows/2"

    for item <- items do
      assert item.condition |> Map.keys() |> Enum.sort() == ~w(cause handled impact next state)a
      assert Enum.all?(Map.values(item.condition), &(&1 != nil)), "#{item.kind}"
    end
  end

  test "a healthy namespace and an open controller have nothing to say" do
    assert Attention.derive(%{
             namespaces: [%{namespace: "d", rows: [row("a")]}],
             authz: %{posture: :open}
           }) == []
  end

  test "tracking keeps first-seen times and reports what came and went" do
    t0 = ~U[2026-10-12 10:00:00Z]
    t1 = ~U[2026-10-12 10:00:10Z]

    first =
      Attention.derive(%{namespaces: [%{namespace: "d", rows: [row("a", %{health: :failed})]}]})

    {tracked, appeared, cleared} = Attention.track(%{}, first, t0)
    assert [%{first_seen: ^t0}] = tracked
    assert length(appeared) == 1 and cleared == []

    second =
      Attention.derive(%{
        namespaces: [
          %{namespace: "d", rows: [row("a", %{health: :failed}), row("b", %{health: :unbound})]}
        ]
      })

    {tracked, appeared, cleared} = Attention.track(Attention.by_id(tracked), second, t1)
    assert Enum.find(tracked, &(&1.object.id == "a")).first_seen == t0
    assert [%{object: %{id: "b"}}] = appeared
    assert cleared == []

    {[], [], [%{object: %{id: "a"}} | _]} = Attention.track(Attention.by_id(tracked), [], t1)
  end

  test "the worst come first, then the longest seen" do
    at = fn s -> DateTime.add(~U[2026-10-12 10:00:00Z], s) end

    items = [
      %{id: "w-old", severity: :warning, first_seen: at.(0)},
      %{id: "n-new", severity: :negative, first_seen: at.(9)},
      %{id: "n-old", severity: :negative, first_seen: at.(1)}
    ]

    assert Attention.order(items) |> Enum.map(& &1.id) == ~w(n-old n-new w-old)
    assert Attention.worst(items) == :negative
    assert Attention.worst([]) == nil
  end
end
