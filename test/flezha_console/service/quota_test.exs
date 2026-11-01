defmodule FlezhaConsole.Service.QuotaTest do
  @moduledoc """
  The two halves of a namespace's limits: `parse_limits/2`, which reads what a
  quota form typed, and `quota_usage/3`, which pairs each counter with the
  limit that governs it and decides whether it is breached.
  """

  use ExUnit.Case, async: false

  alias Flezha.Service.Namespace
  alias FlezhaConsole.FakeListener
  alias FlezhaConsole.Service.NodeManager

  @moduletag :channel
  @token "flzt_t"

  setup_all do
    %{node: FakeListener.start!()}
  end

  describe "parse_limits/2" do
    @keys ~w(max_relays max_runners)a

    for {typed, answer} <- [
          {"10", {:ok, %{max_relays: 10}}},
          {"0", {:ok, %{max_relays: 0}}},
          {" 3 ", {:ok, %{max_relays: 3}}},
          {"", {:ok, %{}}},
          {"   ", {:ok, %{}}},
          {"-1", {:error, "max_relays must be a whole number of 0 or more."}},
          {"1.5", {:error, "max_relays must be a whole number of 0 or more."}},
          {"lots", {:error, "max_relays must be a whole number of 0 or more."}}
        ] do
      test "#{inspect(typed)} answers #{inspect(answer)}" do
        assert NodeManager.parse_limits(%{"max_relays" => unquote(typed)}, @keys) ==
                 unquote(Macro.escape(answer))
      end
    end

    test "a field the form did not post is left out, as a blank one is" do
      assert NodeManager.parse_limits(%{"max_runners" => "4"}, @keys) ==
               {:ok, %{max_runners: 4}}
    end

    test "the first invalid field is the one named" do
      assert NodeManager.parse_limits(%{"max_relays" => "x", "max_runners" => "-2"}, @keys) ==
               {:error, "max_relays must be a whole number of 0 or more."}
    end
  end

  describe "quota_usage/3" do
    setup %{node: node} do
      FakeController.reset(node)
      :ok
    end

    # The kind a counter read names crosses the wire as text.
    defp counters(node, by_kind),
      do:
        FakeController.set(
          node,
          {Namespace, :quota},
          {:per_arg, 1, Map.new(by_kind, fn {kind, usage} -> {to_string(kind), usage} end),
           FakeController.quota_usage(0)}
        )

    defp row(rows, kind), do: Enum.find(rows, &(&1.kind == kind))

    defp judged(rows),
      do: Enum.map(rows, &Map.take(&1, [:kind, :limit_key, :value, :limit, :breached?]))

    test "a counter at its limit is breached, one below it is not", %{node: node} do
      FakeController.set(node, {Namespace, :quota_kinds}, {:ok, [:relays, :runners]})

      counters(node, %{
        relays: FakeController.quota_usage(5),
        runners: FakeController.quota_usage(3)
      })

      assert judged(NodeManager.quota_usage("default", %{max_relays: 5, max_runners: 4}, @token)) ==
               [
                 %{kind: :relays, limit_key: :max_relays, value: 5, limit: 5, breached?: true},
                 %{kind: :runners, limit_key: :max_runners, value: 3, limit: 4, breached?: false}
               ]
    end

    test "relays on two controllers count against one quota as their total", %{node: node} do
      FakeController.set(node, {Namespace, :quota_kinds}, {:ok, [:relays]})
      counters(node, %{relays: FakeController.quota_usage(5, %{flezha@c1: 3, flezha@c2: 2})})

      assert [relays] = NodeManager.quota_usage("default", %{max_relays: 5}, @token)
      assert relays.value == 5
      assert relays.breached?
      assert relays.by_node == %{"flezha@c1" => 3, "flezha@c2" => 2}
      assert relays.unreachable == []
    end

    test "a counter missing a controller names it, and still judges the total it has", %{
      node: node
    } do
      FakeController.set(node, {Namespace, :quota_kinds}, {:ok, [:runners]})
      counters(node, %{runners: FakeController.quota_usage(2, %{flezha@c1: 2}, [:flezha@c2])})

      rows = NodeManager.quota_usage("default", %{max_runners: 4}, @token)

      assert [%{value: 2, breached?: false, unreachable: ["flezha@c2"]}] = rows
      assert NodeManager.unreachable(rows) == ["flezha@c2"]
    end

    test "a kind with no limit, or a namespace with no record, is never breached", %{node: node} do
      FakeController.set(node, {Namespace, :quota_kinds}, {:ok, [:relays]})
      counters(node, %{relays: FakeController.quota_usage(1_000)})

      unlimited = %{kind: :relays, limit_key: :max_relays, value: 1_000, limit: nil}

      assert judged(NodeManager.quota_usage("default", %{max_runners: 4}, @token)) == [
               Map.put(unlimited, :breached?, false)
             ]

      assert judged(NodeManager.quota_usage("default", nil, @token)) == [
               Map.put(unlimited, :breached?, false)
             ]
    end

    test "a refused counter has no value and is not breached", %{node: node} do
      FakeController.set(node, {Namespace, :quota_kinds}, {:ok, [:relays, :cells]})

      counters(node, %{
        relays: FakeController.error("authz.role_insufficient"),
        cells: FakeController.quota_usage(2)
      })

      assert judged(
               NodeManager.quota_usage(
                 "default",
                 %{max_relays: 0, max_cells_per_relay: 2},
                 @token
               )
             ) ==
               [
                 %{kind: :relays, limit_key: :max_relays, value: nil, limit: 0, breached?: false},
                 %{
                   kind: :cells,
                   limit_key: :max_cells_per_relay,
                   value: 2,
                   limit: 2,
                   breached?: true
                 }
               ]
    end

    test "refused kinds fall back to every kind the console can meter", %{node: node} do
      FakeController.set(
        node,
        {Namespace, :quota_kinds},
        FakeController.error("authz.role_insufficient")
      )

      counters(node, %{relays: FakeController.quota_usage(2)})

      rows = NodeManager.quota_usage("default", %{max_relays: 2}, @token)

      assert rows |> Enum.map(& &1.kind) |> Enum.sort() ==
               ~w(cells disk_bytes mailbox_bytes relays runners)a

      assert %{
               kind: :relays,
               limit_key: :max_relays,
               value: 2,
               limit: 2,
               breached?: true
             } = row(rows, :relays)

      assert %{
               kind: :disk_bytes,
               limit_key: :max_state_bytes,
               value: 0,
               limit: nil,
               breached?: false
             } = row(rows, :disk_bytes)

      asked = node |> FakeController.calls({Namespace, :quota}) |> Enum.map(&Enum.at(&1, 1))
      assert Enum.sort(asked) == ~w(cells disk_bytes mailbox_bytes relays runners)
    end
  end
end
