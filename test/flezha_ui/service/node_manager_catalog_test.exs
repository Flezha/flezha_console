defmodule FlezhaUi.Service.NodeManagerCatalogTest do
  @moduledoc """
  The two reads every factory picker and the kind selector are built from.

  Both are pairings rather than passthroughs — a factory listing joined to the
  runners serving each, and a candidate list probed against the controller's own
  kind model — so what they answer when half the pairing fails is the part worth
  pinning down. The pure inversion and the disconnected fallbacks live in
  `FlezhaUi.Service.NodeManagerTest`, which needs no controller.
  """

  use ExUnit.Case, async: false

  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.NodeManager

  @moduletag :distributed

  setup do
    PeerNode.setup_controller("nm_catalog_peer")
  end

  defp with_factories(node, factories) do
    FakeController.set(node, {Flezha, :list_factories}, {:ok, factories})
  end

  defp with_runners(node, by_factory) do
    FakeController.set(
      node,
      {Flezha.Runner.FleetManager, :runners_for_factory},
      {:per_arg, 1, by_factory, []}
    )
  end

  describe "factory_catalog/1" do
    test "pairs each factory with the runners serving it", %{node: node} do
      with_factories(node, [
        %{id: "store_input", description: "stores its input"},
        %{id: "compare_filter", description: "filters"}
      ])

      with_runners(node, %{
        "store_input" => ["runner-b", "runner-a"],
        "compare_filter" => ["runner-a"]
      })

      assert {:ok, catalog} = NodeManager.factory_catalog("default")

      assert [
               %{
                 id: "compare_filter",
                 description: "filters",
                 runners: ["runner-a"],
                 servable?: true
               },
               %{
                 id: "store_input",
                 description: "stores its input",
                 runners: ["runner-a", "runner-b"],
                 servable?: true
               }
             ] = catalog
    end

    test "a registered factory no runner serves is present and not servable", %{node: node} do
      with_factories(node, [%{id: "store_input", description: nil}])
      with_runners(node, %{})

      assert {:ok, [%{id: "store_input", runners: [], servable?: false}]} =
               NodeManager.factory_catalog("default")
    end

    test "a namespace with no registered factories answers an empty catalog", %{node: node} do
      with_factories(node, [])

      assert {:ok, []} = NodeManager.factory_catalog("default")
    end

    test "a refused listing is the catalog's answer, not an empty one", %{node: node} do
      FakeController.set(
        node,
        {Flezha, :list_factories},
        {:error, {:forbidden, :no_role_binding}}
      )

      assert {:error, {:forbidden, :no_role_binding}} = NodeManager.factory_catalog("default")
    end

    test "a refused runner lookup leaves its factory offered but unserved", %{node: node} do
      # The distinction the picker draws: the namespace's factories are known,
      # only which runners serve one is not.
      with_factories(node, [%{id: "store_input", description: nil}])

      FakeController.set(
        node,
        {Flezha.Runner.FleetManager, :runners_for_factory},
        {:error, :timeout}
      )

      assert {:ok, [%{id: "store_input", runners: [], servable?: false}]} =
               NodeManager.factory_catalog("default")
    end
  end

  describe "known_kinds/0" do
    test "offers each recognised kind with the capabilities it declares", %{node: _node} do
      assert [stream, workflow] = NodeManager.known_kinds()

      assert %{kind: :stream, capabilities: capabilities} = stream
      assert :persistent_state? in capabilities
      assert :time_travel? in capabilities

      # A workflow declares none, which is exactly what an operator needs to
      # see before starting one.
      assert %{kind: :workflow, capabilities: []} = workflow
    end

    test "a kind the controller does not recognise is not offered", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Operative.Kind, :known?},
        {:per_arg, 0, %{stream: true}, false}
      )

      assert [%{kind: :stream}] = NodeManager.known_kinds()
    end

    test "a controller with no kind model still offers the candidates", %{node: node} do
      FakeController.set(node, {Flezha.Operative.Kind, :known?}, {:error, :undef})

      assert [%{kind: :stream, capabilities: []}, %{kind: :workflow, capabilities: []}] =
               NodeManager.known_kinds()
    end
  end
end
