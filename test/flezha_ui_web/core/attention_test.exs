defmodule FlezhaUiWeb.AttentionTest do
  @moduledoc """
  The one derivation of open problems, fed the shapes the controller really
  answers: `relay_rows/2` rows, `quota_usage/3` rows, `Dlq.stats/1` rows,
  `durability_breaches/1`, stall verdicts and the authz status map.
  """

  use ExUnit.Case, async: true

  alias FlezhaUiWeb.Attention

  defp row(id, overrides \\ %{}) do
    Map.merge(
      %{id: id, health: :healthy, runner: "r1", factory: "f", partition: nil, node: :flezha@a},
      overrides
    )
  end

  test "a suspended relay says what and why, and offers Diagnose and Open relay" do
    [item] =
      Attention.derive(%{
        namespaces: [%{namespace: "default", rows: [row("testnet_echo", %{health: :suspended})]}]
      })

    assert item.what == "testnet_echo is suspended"
    assert item.why =~ "suspended"
    assert item.severity == :warning
    assert item.namespace == "default"

    assert [
             %{label: "Diagnose", do: :diagnose, operation: "Relay.diagnose"},
             %{label: "Open relay"}
           ] = item.actions
  end

  test "a failed or parked relay is negative; an unplaced one and a faulted group are found too" do
    items =
      Attention.derive(%{
        namespaces: [
          %{
            namespace: "default",
            rows: [
              row("f", %{health: :failed}),
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
    assert by_object["m"].what =~ "broken key range"
    assert by_object["g1"].kind == :partition_group
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
    assert [%{navigate: "/namespaces/default#quotas"}] = item.actions
  end

  test "parked entries name their class and count and link to the filtered dead-letter screen" do
    [item] =
      Attention.derive(%{
        dlq: [
          %{relay_class: "orders", tasklet_id: "t1", entries: 2},
          %{relay_class: "orders", tasklet_id: "t2", entries: 1},
          %{relay_class: "empty", tasklet_id: "t", entries: 0}
        ]
      })

    assert item.what == "3 entries parked for orders"
    assert item.why =~ "Tasklets t1 and t2"
    assert [%{navigate: "/dlq?class=orders"}] = item.actions
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
    assert Enum.find(items, &(&1.kind == :rpo)).what == "2 references past their RPO target"
    assert Enum.find(items, &(&1.kind == :skew)).why =~ "Flezha.Service.Relay.relay_rows/2"
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

  test "the summary's attention list is this derivation's" do
    summary =
      FlezhaUiWeb.Topology.summary(%{
        namespace: "d",
        rows: [row("a", %{health: :suspended})],
        relay_ids: ["a"],
        runners: [],
        snapshot: nil,
        rates: %{},
        dlq: [],
        verdicts: [],
        skew: nil
      })

    assert summary.attention == Attention.relay_items("d", [row("a", %{health: :suspended})])
  end
end
