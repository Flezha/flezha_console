defmodule FlezhaConsole.Service.NodeManagerCatalogTest do
  @moduledoc """
  The reads that are pairings or decodings rather than passthroughs: the
  factory catalog joined to the runners serving each, each relay's run read
  from the registry, the partition groups' coverage, and the fields a start
  sends. What they answer when half the pairing fails, or when the controller
  answers something that is not a relay, is the part worth pinning down. The
  pure helpers and the disconnected fallbacks live in
  `FlezhaConsole.Service.NodeManagerTest`, which needs no controller.
  """

  use ExUnit.Case, async: false

  alias FlezhaConsole.PeerNode
  alias FlezhaConsole.Service.NodeManager

  @moduletag :distributed

  setup_all do
    PeerNode.setup_controller("nm_catalog_peer")
  end

  setup %{node: node} do
    FakeController.reset(node)
    :ok
  end

  defp with_factories(node, factories) do
    FakeController.set(node, {Flezha.Service.Fleet, :factories}, FakeController.rows(factories))
  end

  describe "factory_catalog/2" do
    test "pairs each factory with its run and the runners serving it", %{node: node} do
      with_factories(node, [
        %{
          id: "store_input",
          description: "stores its input",
          run: :flow,
          runners: ["runner-b", "runner-a"]
        },
        %{id: "chat_loop_steps", description: "loops", run: :steps, runners: ["runner-a"]}
      ])

      assert {:ok, %{rows: catalog, unreachable: []}} =
               NodeManager.factory_catalog("default", nil)

      # One listing carries the runners; no factory is looked up on its own.
      assert [_one] = FakeController.calls(node, {Flezha.Service.Fleet, :factories})
      assert FakeController.calls(node, {Flezha.Service.Fleet, :runners_for_factory}) == []

      assert [
               %{
                 id: "chat_loop_steps",
                 description: "loops",
                 run: :steps,
                 runners: ["runner-a"],
                 servable?: true
               },
               %{
                 id: "store_input",
                 description: "stores its input",
                 run: :flow,
                 runners: ["runner-a", "runner-b"],
                 servable?: true
               }
             ] = catalog
    end

    test "a registered factory no runner serves is present and not servable", %{node: node} do
      with_factories(node, [%{id: "store_input", description: nil, run: :flow, runners: []}])

      assert {:ok, %{rows: [%{id: "store_input", runners: [], servable?: false}]}} =
               NodeManager.factory_catalog("default", nil)
    end

    test "a namespace with no registered factories answers an empty catalog", %{node: node} do
      with_factories(node, [])

      assert {:ok, %{rows: []}} = NodeManager.factory_catalog("default", nil)
    end

    test "a catalog missing a controller names it, with the factories the rest serve", %{
      node: node
    } do
      FakeController.set(
        node,
        {Flezha.Service.Fleet, :factories},
        FakeController.rows(
          [%{id: "store_input", description: nil, run: :flow, runners: ["runner-b"]}],
          ["flezha@node-c"]
        )
      )

      answer = NodeManager.factory_catalog("default", nil)

      assert {:ok, %{rows: [%{id: "store_input", servable?: true}]}} = answer
      assert NodeManager.unreachable([answer]) == [:"flezha@node-c"]
      assert NodeManager.ok_or(answer, []) |> Enum.map(& &1.id) == ["store_input"]
    end

    test "a refused listing is the catalog's answer, not an empty one", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Fleet, :factories},
        FakeController.error("authz.no_role_binding")
      )

      assert {:error, %Flezha.Error{code: "authz.no_role_binding"}} =
               NodeManager.factory_catalog("default", nil)
    end

    test "a row that names no runners leaves its factory offered but unserved", %{node: node} do
      # The distinction the picker draws: the namespace's factories are known,
      # only which runners serve one is not.
      with_factories(node, [%{id: "store_input", description: nil, run: :flow}])

      assert {:ok, %{rows: [%{id: "store_input", runners: [], servable?: false}]}} =
               NodeManager.factory_catalog("default", nil)
    end
  end

  describe "relay_runs/2" do
    test "reads each relay's run from its builder and skips what is not a relay", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :registry},
        {:ok,
         %{
           "flow-1" => FakeController.registry_entry(:flow),
           "steps-1" => FakeController.registry_entry(:steps),
           {:plugin, "ws_store_1"} => {%{}, [], %{}}
         }}
      )

      assert {:ok, %{"flow-1" => :flow, "steps-1" => :steps} = runs} =
               NodeManager.relay_runs("default", nil)

      assert map_size(runs) == 2
    end

    test "a builder carrying no run reads as flow", %{node: node} do
      entry = {%{start: {Flezha.Relay, :start_link, [{"default", "runner-a", %{}}]}}, []}
      FakeController.set(node, {Flezha.Service.Relay, :registry}, {:ok, %{"old" => entry}})

      assert {:ok, %{"old" => :flow}} = NodeManager.relay_runs("default", nil)
    end

    test "a refused registry read is reported", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :registry},
        FakeController.error("authz.role_insufficient")
      )

      assert {:error, %Flezha.Error{class: :denied}} = NodeManager.relay_runs("default", nil)
    end
  end

  describe "partition_groups/2" do
    test "decodes each group's coverage verdict", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :partition_groups},
        {:ok,
         [
           %{group: "g1", declared: 2, members: [%{id: "g1#p0"}, %{id: "g1#p1"}], coverage: :ok},
           %{
             group: "g2",
             declared: 2,
             members: [%{id: "g2#p0"}],
             coverage: {:error, %{gaps: [{2048, 4095}], overlaps: []}}
           }
         ]}
      )

      assert [
               %{id: "g1", partitions: "2/2", coverage: :complete},
               %{id: "g2", partitions: "1/2", coverage: %{gaps: [{2048, 4095}], overlaps: []}}
             ] = groups = NodeManager.partition_groups([], nil)

      assert NodeManager.faulted_group_ids(groups) == ["g2"]
    end

    test "a failed read answers no groups rather than raising", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :partition_groups},
        FakeController.error("controller.timeout")
      )

      assert [] = NodeManager.partition_groups([], nil)
    end
  end

  describe "start_relay/3" do
    test "sends the factory, init values and opts, and no run", %{node: node} do
      assert {:ok, %{id: "relay-generated", outcome: :started}} =
               NodeManager.start_relay("default", %{factory_id: "store_input"}, nil)

      assert [["default", relay, %{source: :ui}]] =
               FakeController.calls(node, {Flezha.Service.Relay, :start})

      assert relay == [factory_id: "store_input", init_values: %{}, opts: []]
    end

    test "a blank id is left for the controller to draw; a chosen one is sent", %{node: node} do
      NodeManager.start_relay("default", %{factory_id: "store_input", id: ""}, nil)
      NodeManager.start_relay("default", %{factory_id: "store_input", id: "mine"}, nil)

      assert [["default", blank, _], ["default", chosen, _]] =
               FakeController.calls(node, {Flezha.Service.Relay, :start})

      refute Keyword.has_key?(blank, :id)
      assert chosen[:id] == "mine"
    end

    test "plugins and partitions are sent only when given", %{node: node} do
      NodeManager.start_relay(
        "default",
        %{factory_id: "store_input", plugins: [%{"id" => "p"}], partitions: 3},
        nil
      )

      assert [["default", relay, _]] = FakeController.calls(node, {Flezha.Service.Relay, :start})
      assert relay[:plugins] == [%{"id" => "p"}]
      assert relay[:partitions] == 3
    end
  end

  describe "relay_list/2" do
    test "reads an unobserved row as unknown, never healthy", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :list},
        FakeController.rows([FakeController.relay_row("r1", %{health: nil})])
      )

      assert {:ok, %{rows: [%{id: "r1", health: :unknown}]}} =
               NodeManager.relay_list("default", nil)
    end

    test "a relay hosted on another controller keeps the health that controller decided", %{
      node: node
    } do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :list},
        FakeController.rows([
          FakeController.relay_row("here"),
          FakeController.relay_row("there", %{node: :"flezha@node-b", health: :degraded})
        ])
      )

      assert {:ok, %{rows: [%{id: "here", health: :healthy}, %{id: "there", health: :degraded}]}} =
               NodeManager.relay_list("default", nil)
    end
  end

  describe "last_run/3" do
    test "reads the relay's newest ended record from the relay history", %{node: node} do
      ended = FakeController.history_record("done", %{"event" => "ended", "outcome" => "failed"})

      FakeController.set(
        node,
        {Flezha.Service.Logs, :read},
        FakeController.log_page([ended], "c1")
      )

      assert {:ok, ^ended} = NodeManager.last_run("default", "done", nil)

      assert [[params, %{source: :ui}]] =
               FakeController.calls(node, {Flezha.Service.Logs, :read})

      assert params[:kind] == "relay_history"
      assert params[:limit] == 1

      assert params[:filters] == %{
               "namespace" => "default",
               "relay" => "done",
               "event" => "ended"
             }
    end

    test "answers nil for a relay the history never saw end", %{node: _node} do
      assert {:ok, nil} = NodeManager.last_run("default", "never", nil)
    end

    test "passes a refusal on", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Logs, :read},
        FakeController.error("authz.role_insufficient")
      )

      assert {:error, %Flezha.Error{code: "authz.role_insufficient"}} =
               NodeManager.last_run("default", "done", nil)
    end
  end
end
