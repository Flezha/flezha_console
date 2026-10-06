defmodule FlezhaUi.Service.NodeManagerTest do
  @moduledoc """
  The pieces of `NodeManager` that decide whether a controller change is
  diagnosable or a mystery: how failures are classified while no controller is
  reachable, and the pure helpers every screen reads rows through.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FlezhaUi.Service.NodeManager

  describe "erpc_call/3 error classification" do
    test "answers :node_not_connected when no controller is reachable" do
      # No node is connected in the test VM, which is the disconnected case.
      assert {:error, :node_not_connected} =
               NodeManager.erpc_call(Flezha.AuthZ, :enforcement_posture, [])
    end

    test "every controller call degrades instead of raising while disconnected" do
      for call <- controller_calls() do
        assert {:error, :node_not_connected} = call.()
      end
    end
  end

  # Every call the screens make. A new one added without a normalised failure
  # path shows up here as a raise rather than as a banner.
  defp controller_calls do
    [
      fn -> NodeManager.list_namespaces(nil) end,
      fn -> NodeManager.list_relays("default", nil) end,
      fn -> NodeManager.relay_list("default", nil) end,
      fn -> NodeManager.relay_rows("default", nil) end,
      fn -> NodeManager.relay_plugins("default", nil) end,
      fn -> NodeManager.relay_runs("default", nil) end,
      fn -> NodeManager.runners("default", nil) end,
      fn -> NodeManager.factories("default", nil) end,
      fn -> NodeManager.factory_catalog("default", nil) end,
      fn -> NodeManager.start_relay("default", %{factory_id: "store_input"}, nil) end,
      fn -> NodeManager.stop_relay("default", "r1", nil) end,
      fn -> NodeManager.cell_state("default", "r1", nil, nil) end,
      fn -> NodeManager.overwatch_state("default", "r1", nil) end,
      fn -> NodeManager.overwatch_facts("default", "r1", nil) end,
      fn -> NodeManager.finished_relays("default", nil) end,
      fn -> NodeManager.task_journal("r1", nil) end,
      fn -> NodeManager.plugins("default", nil) end,
      fn -> NodeManager.providers(nil) end,
      fn -> NodeManager.disable_plugin("p1", "default", nil) end,
      fn -> NodeManager.dlq_list(nil, nil) end,
      fn -> NodeManager.dlq_get("a/b/c", nil) end,
      fn -> NodeManager.dlq_stats(nil) end,
      fn -> NodeManager.schedule_list(nil) end,
      fn -> NodeManager.audit_files(nil) end,
      fn -> NodeManager.audit_stats(nil) end,
      fn -> NodeManager.controller_status(nil) end,
      fn -> NodeManager.cluster_status("default", nil) end,
      fn -> NodeManager.liveness_snapshot(nil) end,
      fn -> NodeManager.namespace_records(nil) end,
      fn -> NodeManager.audit_tail(nil, self()) end,
      fn -> NodeManager.listen("default", "r1", :output, nil, self()) end
    ]
  end

  describe "ok_or/2" do
    test "takes the value out of a success" do
      assert [1, 2] = NodeManager.ok_or({:ok, [1, 2]}, [])
    end

    test "falls back on a failure, so one dead section does not empty a page" do
      assert [] = NodeManager.ok_or({:error, :node_not_connected}, [])
      assert nil == NodeManager.ok_or({:error, :timeout}, nil)
    end
  end

  describe "scoped_namespaces/1" do
    test "answers no names and the reason while disconnected" do
      assert {[], :node_not_connected} = NodeManager.scoped_namespaces(nil)
    end
  end

  describe "health_verdicts/0" do
    test "follows the controller's rank order, recovering and parked included" do
      assert NodeManager.health_verdicts() == [
               :healthy,
               :unknown,
               :suspended,
               :degraded,
               :recovering,
               :unbound,
               :failed,
               :parked
             ]
    end

    test "health_counts/1 gives every verdict its own bucket, in rank order" do
      rows = [%{health: :parked}, %{health: :recovering}, %{health: :healthy}, %{}]

      assert [healthy: 1, unknown: 1, recovering: 1, parked: 1] =
               NodeManager.health_counts(rows)
    end

    test "health_counts/1 keeps a verdict it does not know under its own name" do
      assert [healthy: 1, novel: 1] =
               NodeManager.health_counts([%{health: :novel}, %{health: :healthy}])
    end
  end

  describe "factories_by_runner/1" do
    test "inverts a catalog onto the runners serving each factory" do
      catalog = [
        %{id: "compare_filter", description: nil, runners: ["runner-a"], servable?: true},
        %{id: "store_input", description: nil, runners: ["runner-b", "runner-a"], servable?: true}
      ]

      assert %{
               "runner-a" => ["compare_filter", "store_input"],
               "runner-b" => ["store_input"]
             } = NodeManager.factories_by_runner(catalog)
    end

    test "a factory no runner serves contributes no entry" do
      catalog = [%{id: "store_input", description: nil, runners: [], servable?: false}]

      assert %{} == NodeManager.factories_by_runner(catalog)
    end
  end

  describe "hook_entries/1" do
    test "flattens a hook table into one row per binding" do
      state = %{
        extensions: %{
          subs: %{
            on_input: [
              %{plugin_id: "b", provider: Flezha.Plugin.Provider.StdOut, position: 1},
              %{plugin_id: "a", provider: Flezha.Plugin.Provider.Filter, position: 0}
            ],
            on_terminate: [%{plugin_id: "c", provider: Flezha.Plugin.Provider.Websocket}]
          }
        }
      }

      rows = NodeManager.hook_entries(state)

      assert [
               %{plugin_id: "a", hook: "on_input", position: 0},
               %{plugin_id: "b", hook: "on_input", position: 1},
               %{plugin_id: "c", hook: "on_terminate"}
             ] = rows

      assert Enum.at(rows, 0).provider =~ "Filter"
    end

    test "a relay with no plugins yields no rows" do
      assert [] = NodeManager.hook_entries(%{extensions: %{subs: %{}}})
    end

    test "a state without a hook table yields no rows rather than raising" do
      assert [] = NodeManager.hook_entries(%{})
      assert [] = NodeManager.hook_entries(nil)
    end

    test "renders a missing provider as a placeholder" do
      state = %{extensions: %{subs: %{on_input: [%{plugin_id: "a"}]}}}
      assert [%{provider: "—"}] = NodeManager.hook_entries(state)
    end
  end

  describe "overwatch_facts/0" do
    test "is the decoded shape with nothing in it, a flow relay with no plugins" do
      assert %{run: :flow, durable_steps: false, bindings: [], relay_class: nil} =
               NodeManager.overwatch_facts()
    end
  end

  describe "parse_init_values/1" do
    test "blank means no init values" do
      assert {:ok, %{}} = NodeManager.parse_init_values("  ")
      assert {:ok, %{}} = NodeManager.parse_init_values(nil)
    end

    test "decodes JSON, and says what is wrong when it is not" do
      assert {:ok, %{"a" => 1}} = NodeManager.parse_init_values(~s({"a": 1}))
      assert {:error, "Init Values must be valid JSON."} = NodeManager.parse_init_values("{")
    end
  end

  describe "caller_context/1" do
    test "identifies this UI as the caller" do
      assert %{source: :ui} == NodeManager.caller_context(nil)
    end

    test "a caller-supplied value is not a principal" do
      # Identity comes only from a verified token, and with no controller to
      # verify against nothing binds — a name typed into the UI never can.
      assert %{source: :ui} == NodeManager.caller_context("svc-ui")
    end
  end

  describe "logging" do
    test "a disconnected call stays quiet" do
      log = capture_log(fn -> NodeManager.list_namespaces(nil) end)
      refute log =~ "diverged"
    end
  end
end
