defmodule FlezhaConsole.Service.QuotaTest do
  @moduledoc """
  The two halves of a namespace's limits: `parse_limits/2`, which reads what a
  quota form typed, and `quota_usage/3`, which pairs each counter with the
  limit that governs it and decides whether it is breached.
  """

  use ExUnit.Case, async: false

  alias Flezha.Service.Namespace
  alias FlezhaConsole.PeerNode
  alias FlezhaConsole.Service.NodeManager

  @moduletag :distributed

  setup_all do
    PeerNode.setup_controller("quota_peer")
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

    defp counters(node, by_kind),
      do: FakeController.set(node, {Namespace, :quota}, {:per_arg, 1, by_kind, {:ok, 0}})

    defp row(rows, kind), do: Enum.find(rows, &(&1.kind == kind))

    test "a counter at its limit is breached, one below it is not", %{node: node} do
      FakeController.set(node, {Namespace, :quota_kinds}, {:ok, [:relays, :runners]})
      counters(node, %{relays: {:ok, 5}, runners: {:ok, 3}})

      assert NodeManager.quota_usage("default", %{max_relays: 5, max_runners: 4}, nil) == [
               %{kind: :relays, limit_key: :max_relays, value: 5, limit: 5, breached?: true},
               %{kind: :runners, limit_key: :max_runners, value: 3, limit: 4, breached?: false}
             ]
    end

    test "a kind with no limit, or a namespace with no record, is never breached", %{node: node} do
      FakeController.set(node, {Namespace, :quota_kinds}, {:ok, [:relays]})
      counters(node, %{relays: {:ok, 1_000}})

      unlimited = %{kind: :relays, limit_key: :max_relays, value: 1_000, limit: nil}

      assert NodeManager.quota_usage("default", %{max_runners: 4}, nil) == [
               Map.put(unlimited, :breached?, false)
             ]

      assert NodeManager.quota_usage("default", nil, nil) == [
               Map.put(unlimited, :breached?, false)
             ]
    end

    test "a refused counter has no value and is not breached", %{node: node} do
      FakeController.set(node, {Namespace, :quota_kinds}, {:ok, [:relays, :cells]})

      counters(node, %{
        relays: FakeController.error("authz.role_insufficient"),
        cells: {:ok, 2}
      })

      assert NodeManager.quota_usage("default", %{max_relays: 0, max_cells_per_relay: 2}, nil) ==
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

      counters(node, %{relays: {:ok, 2}})

      rows = NodeManager.quota_usage("default", %{max_relays: 2}, nil)

      assert rows |> Enum.map(& &1.kind) |> Enum.sort() ==
               ~w(cells disk_bytes mailbox_bytes relays runners)a

      assert row(rows, :relays) == %{
               kind: :relays,
               limit_key: :max_relays,
               value: 2,
               limit: 2,
               breached?: true
             }

      assert row(rows, :disk_bytes) == %{
               kind: :disk_bytes,
               limit_key: :max_state_bytes,
               value: 0,
               limit: nil,
               breached?: false
             }

      asked = node |> FakeController.calls({Namespace, :quota}) |> Enum.map(&Enum.at(&1, 1))
      assert Enum.sort(asked) == ~w(cells disk_bytes mailbox_bytes relays runners)a
    end
  end
end
