defmodule FlezhaConsole.Service.DevSetupTest do
  @moduledoc """
  The dev seeder's controller-facing paths.

  Driven against a peer standing in for the controller rather than the live
  dev stack, because the states worth asserting — a namespace already declared,
  a controller that refuses the declaration, a relay already running — are
  exactly the ones a working dev stack will not produce on demand.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Flezha.Service.Fleet
  alias Flezha.Service.Namespace
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay
  alias FlezhaConsole.PeerNode
  alias FlezhaConsole.Service.DevSetup
  alias FlezhaConsole.TestEnv

  @moduletag :distributed

  @namespace "seeded"

  setup_all do
    PeerNode.setup_controller("dev_setup_peer")
  end

  setup %{node: node} do
    FakeController.reset(node)

    FakeController.set(
      node,
      {Relay, :list_namespaces},
      FakeController.rows([%{namespace: @namespace, running: true}])
    )
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

    TestEnv.put_app(:dev_setup, config)
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
      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows([FakeController.relay_row("relay_a")])
      )

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
        FakeController.rows([%{namespace: @namespace, running: false}])
      )

      configure(relays: [relay("relay_a")])

      refute seed!().ready
      assert FakeController.calls(node, {Relay, :start}) == []
    end
  end

  @plugin %{
    name: "ws_a",
    relay_id: "relay_a",
    provider: "relay_websocket",
    hooks: ["on_terminate"],
    opts: %{"uri" => "ws://example:4500"}
  }

  describe "an optional seed" do
    @showcase %{id: "testnet_showcase", factory_id: "showcase", init_values: %{}, optional: true}
    @showcase_plugin %{@plugin | name: "ws_showcase", relay_id: "testnet_showcase"}

    test "is skipped with one log line, with its plugins, when no runner announces its factory",
         %{node: node} do
      FakeController.set(
        node,
        {Fleet, :factories},
        FakeController.rows([%{id: "store_input", run: :flow}])
      )

      configure(relays: [relay("relay_a"), @showcase], plugins: [@showcase_plugin])

      log = capture_log(fn -> assert seed!().ready end)

      assert log =~ "Skipped testnet_showcase: no runner announces factory showcase"
      assert [["seeded", fields, _ctx]] = FakeController.calls(node, {Relay, :start})
      assert fields[:id] == "relay_a"
      assert FakeController.calls(node, {PluginManager, :enable}) == []
    end

    test "is started like any other when its factory is announced, and again leaves it alone",
         %{node: node} do
      FakeController.set(
        node,
        {Fleet, :factories},
        FakeController.rows([%{id: "showcase", run: :flow}])
      )

      configure(relays: [@showcase], plugins: [@showcase_plugin])

      assert seed!().ready
      assert [["seeded", fields, _ctx]] = FakeController.calls(node, {Relay, :start})
      assert fields[:factory_id] == "showcase"
      refute Keyword.has_key?(fields, :optional)

      assert [["ws_showcase", _fields, _ctx]] =
               FakeController.calls(node, {PluginManager, :enable})

      GenServer.stop(DevSetup)

      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows([FakeController.relay_row("testnet_showcase")])
      )

      assert seed!().ready
      assert length(FakeController.calls(node, {Relay, :start})) == 1
    end
  end

  describe "seeding plugins" do
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
