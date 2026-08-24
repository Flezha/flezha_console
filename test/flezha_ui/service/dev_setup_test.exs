defmodule FlezhaUi.Service.DevSetupTest do
  @moduledoc """
  The dev seeder's controller-facing paths.

  Driven against a peer standing in for the controller rather than the live
  dev stack, because the states worth asserting — a namespace already declared,
  a controller that refuses the declaration, one that does not have a namespace
  store at all — are exactly the ones a working dev stack will not produce.
  """

  use ExUnit.Case, async: false

  alias Flezha.AuthZ.NamespaceStore
  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.DevSetup

  @moduletag :distributed

  @namespace "seeded"

  setup do
    %{node: node} = context = PeerNode.setup_controller("dev_setup_peer")

    FakeController.set(node, {Flezha, :list_namespaces}, {:ok, [@namespace]})

    previous = Application.get_env(:flezha_ui, :dev_setup)
    on_exit(fn -> Application.put_env(:flezha_ui, :dev_setup, previous) end)

    context
  end

  defp configure(overrides) do
    config =
      Keyword.merge(
        [
          enabled: true,
          namespace: @namespace,
          quotas: %{max_operatives: 50},
          operatives: [],
          plugins: []
        ],
        overrides
      )

    Application.put_env(:flezha_ui, :dev_setup, config)
  end

  # The seeder retries on failure, so a run is driven to its first outcome and
  # then stopped rather than left ticking into the next test.
  defp seed! do
    {:ok, pid} = DevSetup.start_link([])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :sys.get_state(pid)
  end

  describe "declaring the namespace" do
    test "declares it with the configured quotas", %{node: node} do
      configure([])
      state = seed!()

      assert state.ready

      assert [[@namespace, opts]] = FakeController.calls(node, {NamespaceStore, :create})
      assert Keyword.get(opts, :quotas) == %{max_operatives: 50}
    end

    test "a re-run against a declared namespace is not an error", %{node: node} do
      FakeController.set(node, {NamespaceStore, :create}, {:error, :already_exists})
      configure([])

      assert seed!().ready
      assert length(FakeController.calls(node, {NamespaceStore, :create})) == 1
    end

    test "a controller with no namespace store still gets its operatives", %{node: node} do
      FakeController.set(
        node,
        {NamespaceStore, :create},
        {:error, {:api_missing, NamespaceStore, :create, 2}}
      )

      configure(operatives: [%{id: "op_a", factory_id: "store_input", init_values: %{}}])

      assert seed!().ready
      assert [["seeded", %{id: "op_a"}]] = FakeController.calls(node, {Flezha, :start_operative})
    end

    test "a refused declaration does not stop the rest of the seeding", %{node: node} do
      FakeController.set(
        node,
        {NamespaceStore, :create},
        {:error, {:forbidden, :role_insufficient}}
      )

      configure(operatives: [%{id: "op_a", factory_id: "store_input", init_values: %{}}])

      assert seed!().ready
      assert [["seeded", %{id: "op_a"}]] = FakeController.calls(node, {Flezha, :start_operative})
    end

    test "a declaration that fails for another reason is retried, not ignored", %{node: node} do
      FakeController.set(node, {NamespaceStore, :create}, {:error, :disk_full})
      configure([])

      refute seed!().ready
    end
  end

  describe "seeding operatives" do
    test "starts both kinds, each with the kind it was configured with", %{node: node} do
      configure(
        operatives: [
          %{id: "op_stream", factory_id: "store_input", init_values: %{}},
          %{
            id: "op_workflow",
            factory_id: "chat_loop_workflow",
            init_values: %{},
            kind: :workflow
          }
        ]
      )

      assert seed!().ready

      kinds =
        node
        |> FakeController.calls({Flezha, :start_operative})
        |> Map.new(fn [_ns, operative] -> {operative.id, operative.kind} end)

      assert kinds == %{"op_stream" => :stream, "op_workflow" => :workflow}
    end

    test "an operative that is already running is left alone", %{node: node} do
      FakeController.set(node, {Flezha, :list_operatives}, {:ok, ["op_a"]})
      configure(operatives: [%{id: "op_a", factory_id: "store_input", init_values: %{}}])

      assert seed!().ready
      assert FakeController.calls(node, {Flezha, :start_operative}) == []
    end

    test "waits rather than seeding into a namespace with no running hub", %{node: node} do
      FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["other"]})
      configure(operatives: [%{id: "op_a", factory_id: "store_input", init_values: %{}}])

      refute seed!().ready
      assert FakeController.calls(node, {Flezha, :start_operative}) == []
    end
  end
end
