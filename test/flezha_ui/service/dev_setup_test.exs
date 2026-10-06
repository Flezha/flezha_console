defmodule FlezhaUi.Service.DevSetupTest do
  @moduledoc """
  The dev seeder's controller-facing paths.

  Driven against a peer standing in for the controller rather than the live
  dev stack, because the states worth asserting — a namespace already declared,
  a controller that refuses the declaration, a relay already running — are
  exactly the ones a working dev stack will not produce on demand.
  """

  use ExUnit.Case, async: false

  alias Flezha.Service.Namespace
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay
  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.DevSetup

  @moduletag :distributed

  @namespace "seeded"

  setup do
    %{node: node} = context = PeerNode.setup_controller("dev_setup_peer")

    FakeController.set(
      node,
      {Relay, :list_namespaces},
      {:ok, [%{namespace: @namespace, running: true}]}
    )

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
          quotas: %{max_relays: 50},
          relays: [],
          plugins: []
        ],
        overrides
      )

    Application.put_env(:flezha_ui, :dev_setup, config)
  end

  defp relay(id, factory_id \\ "store_input"),
    do: %{id: id, factory_id: factory_id, init_values: %{}}

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

      assert [[@namespace, opts, %{source: :ui}]] =
               FakeController.calls(node, {Namespace, :create})

      assert Keyword.get(opts, :quotas) == %{max_relays: 50}
    end

    test "a re-run against a declared namespace is not an error", %{node: node} do
      FakeController.set(
        node,
        {Namespace, :create},
        FakeController.error("namespace.already_exists")
      )

      configure([])

      assert seed!().ready
      assert length(FakeController.calls(node, {Namespace, :create})) == 1
    end

    test "a refused declaration does not stop the rest of the seeding", %{node: node} do
      FakeController.set(
        node,
        {Namespace, :create},
        FakeController.error("authz.role_insufficient")
      )

      configure(relays: [relay("relay_a")])

      assert seed!().ready
      assert [["seeded", fields, _ctx]] = FakeController.calls(node, {Relay, :start})
      assert fields[:id] == "relay_a"
    end

    test "a declaration that fails for another reason is retried, not ignored", %{node: node} do
      FakeController.set(node, {Namespace, :create}, FakeController.error("controller.timeout"))
      configure([])

      refute seed!().ready
    end
  end

  describe "seeding relays" do
    test "starts each relay with its factory and no run", %{node: node} do
      configure(relays: [relay("relay_flow"), relay("relay_steps", "chat_loop_steps")])

      assert seed!().ready

      started =
        node
        |> FakeController.calls({Relay, :start})
        |> Map.new(fn [_ns, fields, _ctx] -> {fields[:id], fields} end)

      assert started["relay_flow"][:factory_id] == "store_input"
      assert started["relay_steps"][:factory_id] == "chat_loop_steps"
      refute Enum.any?(started, fn {_id, fields} -> Keyword.has_key?(fields, :run) end)
    end

    test "a relay that is already running is left alone", %{node: node} do
      FakeController.set(node, {Relay, :list_relays}, {:ok, ["relay_a"]})
      configure(relays: [relay("relay_a")])

      assert seed!().ready
      assert FakeController.calls(node, {Relay, :start}) == []
    end

    test "an already-running answer counts as seeded", %{node: node} do
      FakeController.set(
        node,
        {Relay, :start},
        {:ok, %{id: "relay_a", outcome: :already_running}}
      )

      configure(relays: [relay("relay_a")])

      assert seed!().ready
    end

    test "waits rather than seeding into a namespace with no running hub", %{node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        {:ok, [%{namespace: @namespace, running: false}]}
      )

      configure(relays: [relay("relay_a")])

      refute seed!().ready
      assert FakeController.calls(node, {Relay, :start}) == []
    end
  end

  describe "seeding plugins" do
    @plugin %{
      name: "ws_a",
      relay_id: "relay_a",
      provider: "relay_websocket",
      hooks: ["on_terminate"],
      opts: %{"uri" => "ws://example:4500"}
    }

    test "enables each plugin by name, bound to its relay on its seeded hooks", %{node: node} do
      configure(plugins: [@plugin])

      assert seed!().ready

      assert [["ws_a", fields, %{source: :ui}]] =
               FakeController.calls(node, {PluginManager, :enable})

      assert fields[:provider] == "relay_websocket"
      assert fields[:relay_id] == "relay_a"
      assert fields[:namespace] == @namespace
      assert fields[:hooks] == ["on_terminate"]
      assert fields[:opts] == %{"uri" => "ws://example:4500"}
    end

    test "a plugin already enabled counts as seeded", %{node: node} do
      FakeController.set(
        node,
        {PluginManager, :enable},
        {:ok, %{name: "ws_a", outcome: :already_enabled, bound: "relay_a", lacking: []}}
      )

      configure(plugins: [@plugin])

      assert seed!().ready
      assert [["ws_a", _fields, _ctx]] = FakeController.calls(node, {PluginManager, :enable})
    end

    test "a refused enable is retried, not ignored", %{node: node} do
      FakeController.set(
        node,
        {PluginManager, :enable},
        FakeController.error("plugin.unknown_options")
      )

      configure(plugins: [@plugin])

      refute seed!().ready
    end
  end
end
