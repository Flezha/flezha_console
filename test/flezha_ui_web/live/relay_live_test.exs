defmodule FlezhaUiWeb.RelayLiveTest do
  @moduledoc """
  The relay detail screen.

  The browser suite drives attach and detach against a real controller, which
  is the only place the provider forms can be trusted. Covered here: the
  overwatch panel's shape, the cell-state reader, the payload tap, the attach
  form's call, and the refusals — a controller that will not stop the relay,
  will not report its state, or has diverged from this UI's API.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay

  @url "/namespaces/default/relays/relay_a"

  @bound %{
    subs: %{on_input: [%{plugin_id: "plug_1", provider: Flezha.Plugin.Provider.StdOut}]}
  }

  defp overwatch(node, state) do
    FakeController.set(node, {Relay, :overwatch_state}, {:ok, state})
  end

  defp registry_row(node, overrides) do
    row = FakeController.relay_row("relay_a", overrides)

    FakeController.set(node, {Relay, :relay_rows}, {:ok, [row]})
  end

  describe "registry facts" do
    test "health and node come from the namespace's rows", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{health: :degraded, node: :"flezha@node-b"})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="relay-health")
      assert html =~ ~s(data-health="degraded")
      assert html =~ ~s(data-testid="relay-node")
      assert html =~ "flezha@node-b"
    end

    test "a relay with no live node reads as unplaced", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{node: nil})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "unplaced"
    end

    test "a partition member shows its index, key range and group", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})

      registry_row(node, %{
        partition: %{group: "orders", index: 1, count: 4, range: {64, 127}}
      })

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="relay-partition")
      assert html =~ "p1/4"
      assert html =~ "64–127"
      assert html =~ ~s(data-testid="relay-partition-group")
      assert html =~ "orders"
    end

    test "a relay with no partition shows no partition panel", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{})

      {:ok, _view, html} = live(conn, @url)

      refute html =~ ~s(data-testid="relay-partition")
    end

    test "a relay absent from the rows still renders its overwatch facts", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input"})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "store_input"
      refute html =~ ~s(data-health=)
    end
  end

  describe "the overwatch panel" do
    test "renders what the controller reports about the relay", %{conn: conn, node: node} do
      overwatch(node, %{
        factory_id: "store_input",
        runner_id: "runner-a",
        started_at: System.system_time(:millisecond) - 60_000,
        suspended: false,
        effectively_once: true,
        default_input_type: "2"
      })

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "store_input"
      assert html =~ ~s(data-testid="relay-runner")
      assert html =~ "runner-a"
      assert html =~ ~s(data-testid="relay-run")
      assert html =~ ~s(data-testid="relay-uptime")
      assert html =~ ~s(data-testid="relay-effectively-once")
    end

    test "takes the run from the builder, and a builder without one runs as flow", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input", builder: %{run: :steps, opts: []}})
      {:ok, _view, html} = live(conn, @url)
      assert html =~ ~r/data-testid="relay-run"[^>]*>\s*steps/

      overwatch(node, %{factory_id: "store_input", builder: %{opts: []}})
      {:ok, _view, html} = live(conn, @url)
      assert html =~ ~r/data-testid="relay-run"[^>]*>\s*flow/
    end

    test "marks a suspended relay", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input", suspended: true})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="relay-suspended")
    end

    test "renders a controller refusal with its code instead of crashing", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :overwatch_state},
        FakeController.error("authz.role_insufficient", "your role cannot read this relay")
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "authz.role_insufficient"
      assert html =~ "your role cannot read this relay"
    end

    test "reports version skew by naming the missing call", %{conn: conn, node: node} do
      # Turning a remote `:undef` into `:api_missing` is `NodeManager`'s job and
      # is covered in `node_manager_distributed_test`; what matters here is that
      # the screen tells an operator the two have diverged rather than that
      # something merely broke.
      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:error, {:api_missing, Relay, :overwatch_state, 3}}
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "diverged"
      assert html =~ "overwatch_state/3"
    end
  end

  describe "a finished relay" do
    test "shows its completion record and offers no live actions", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :overwatch_state}, FakeController.error("relay.not_found"))

      FakeController.set(
        node,
        {Flezha.Service.Steps, :completion},
        {:ok, %{status: :completed, finished_at: System.system_time(:second)}}
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="completion-record")
      assert html =~ "completed"
      refute html =~ ~s(data-testid="stop-relay-btn")

      # Read on each mount, never on a tick.
      calls = FakeController.calls(node, {Flezha.Service.Steps, :completion})
      assert calls != []
      assert Enum.all?(calls, &match?(["relay_a", %{source: :ui}], &1))
    end
  end

  describe "plugin bindings" do
    test "lists the hooks bound on the relay", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input", extensions: @bound})

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "plugins")

      assert html =~ ~s(data-testid="bindings-table")
      assert html =~ ~s(data-testid="binding-row-plug_1")
      assert html =~ "Flezha.Plugin.Provider.StdOut"
      assert html =~ "on_input"
    end

    test "explains a relay with no plugins", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "plugins")

      assert html =~ ~s(data-testid="no-plugins-msg")
    end

    test "disabling is confirm-gated and cancelling reaches nothing", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input", extensions: @bound})

      {:ok, view, _html} = live(conn, @url)

      html = render_click(view, "confirm_detach", %{"plugin_id" => "plug_1"})
      assert html =~ ~s(data-testid="detach-confirm-modal")

      html = render_click(view, "cancel_detach", %{})
      refute html =~ ~s(data-testid="detach-confirm-modal")
      assert FakeController.calls(node, {PluginManager, :disable}) == []
    end

    test "confirming disables the plugin by name in the relay's namespace", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input", extensions: @bound})

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "confirm_detach", %{"plugin_id" => "plug_1"})

      assert render_click(view, "detach_plugin", %{"plugin_id" => "plug_1"}) =~
               "Plugin plug_1 disabled."

      assert [["plug_1", [namespace: "default"], %{source: :ui}]] =
               FakeController.calls(node, {PluginManager, :disable})
    end

    test "a refused disable is reported rather than shown as success", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input", extensions: @bound})

      FakeController.set(
        node,
        {PluginManager, :disable},
        FakeController.error("plugin.not_found")
      )

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "confirm_detach", %{"plugin_id" => "plug_1"})

      html = render_click(view, "detach_plugin", %{"plugin_id" => "plug_1"})
      assert html =~ "plugin.not_found (test)"
      refute html =~ "disabled."
    end
  end

  describe "attaching a plugin" do
    setup %{node: node} do
      overwatch(node, %{factory_id: "store_input"})

      FakeController.set(
        node,
        {Fleet, :providers},
        {:ok,
         %{
           providers: [%{id: "relay_stdout", module: "Flezha.Plugin.Provider.StdOut", type: :io}],
           refused: 0
         }}
      )

      FakeController.set(
        node,
        {Fleet, :provider},
        {:ok,
         %{
           provider: "relay_stdout",
           help: "Writes each output to stdout.",
           type: :io,
           hooks: [:on_input, :on_output]
         }}
      )

      :ok
    end

    test "offers the provider's own hooks and help", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)

      assert open_attach(view) =~ ~s(data-testid="provider-btn-relay_stdout")
      html = render_click(view, "plugin_form_provider", %{"provider" => "relay_stdout"})

      assert html =~ ~s(data-testid="input-hook-on_input")
      assert html =~ ~s(data-testid="input-hook-on_output")
      assert html =~ "Writes each output to stdout."
    end

    test "enables the plugin by name, bound to this relay, with text-keyed options", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @url)
      open_attach(view)
      render_click(view, "plugin_form_provider", %{"provider" => "relay_stdout"})

      html =
        render_submit(view, "plugin_form_submit", %{
          "plugin" => %{
            "name" => "out_1",
            "hooks" => ["", "on_output"],
            "opts" => ~s({"prefix": "out"})
          }
        })

      assert html =~ "Plugin out_1 enabled and bound to relay_a."

      assert [["out_1", fields, %{source: :ui}]] =
               FakeController.calls(node, {PluginManager, :enable})

      assert fields[:provider] == "relay_stdout"
      assert fields[:opts] == %{"prefix" => "out"}
      assert fields[:namespace] == "default"
      assert fields[:relay_id] == "relay_a"
      assert fields[:hooks] == ["on_output"]
    end

    test "options that are not a JSON object are refused before any call", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @url)
      open_attach(view)
      render_click(view, "plugin_form_provider", %{"provider" => "relay_stdout"})

      html =
        render_submit(view, "plugin_form_submit", %{
          "plugin" => %{"name" => "out_1", "opts" => "[1, 2]"}
        })

      assert html =~ "Options must be a JSON object."
      assert FakeController.calls(node, {PluginManager, :enable}) == []
    end

    test "a plugin already enabled is reported as bound", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {PluginManager, :enable},
        {:ok, %{name: "out_1", outcome: :already_enabled, bound: "relay_a", lacking: []}}
      )

      {:ok, view, _html} = live(conn, @url)
      open_attach(view)
      render_click(view, "plugin_form_provider", %{"provider" => "relay_stdout"})

      assert render_submit(view, "plugin_form_submit", %{"plugin" => %{"name" => "out_1"}}) =~
               "Plugin out_1 was already enabled; this relay is bound to it."
    end

    test "a rejected plugin states the controller's error on the form", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {PluginManager, :enable},
        FakeController.error("plugin.unknown_options", "a relay_stdout plugin has no option x")
      )

      {:ok, view, _html} = live(conn, @url)
      open_attach(view)
      render_click(view, "plugin_form_provider", %{"provider" => "relay_stdout"})

      html = render_submit(view, "plugin_form_submit", %{"plugin" => %{"name" => "out_1"}})
      assert html =~ ~s(data-testid="attach-error")
      assert html =~ "a relay_stdout plugin has no option x"
    end
  end

  describe "the payload tap" do
    setup %{node: node} do
      overwatch(node, %{factory_id: "store_input"})
      :ok
    end

    test "listens to the chosen direction and meters what arrives", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      render_click(view, "graph_tap", %{"direction" => "output"})

      key = {Relay, :listen}
      assert PeerNode.eventually(fn -> FakeController.streams(node, key) != [] end)

      assert [["default", "relay_a", :output, [], %{source: :ui}]] =
               FakeController.calls(node, key)

      FakeController.emit(node, key, {:output, "hello", %{}})

      assert PeerNode.eventually(fn -> render(view) =~ "hello" end)
      html = render(view)
      assert html =~ ~s(data-testid="tap-figures")
      assert html =~ "5 B"
    end

    test "closing the tap ends the listen on the controller", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      render_click(view, "graph_tap", %{"direction" => "input"})

      key = {Relay, :listen}
      assert PeerNode.eventually(fn -> FakeController.streams(node, key) != [] end)

      render_click(view, "graph_tap_close", %{})

      assert PeerNode.eventually(fn -> FakeController.streams(node, key) == [] end)
    end

    test "a tap whose listen ended says so", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      render_click(view, "graph_tap", %{"direction" => "output"})

      key = {Relay, :listen}
      assert PeerNode.eventually(fn -> FakeController.streams(node, key) != [] end)

      FakeController.end_stream(node, key, {:ok, :relay_ended})

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tap-ended") end)
      refute render(view) =~ "Waiting for a record"
    end

    test "a refused tap states the refusal", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :listen},
        FakeController.error("authz.role_insufficient", "no listening for you")
      )

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "graph_tap", %{"direction" => "output"})

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tap-error") end)
      assert render(view) =~ "no listening for you"
    end
  end

  describe "stopping the relay" do
    setup %{node: node} do
      overwatch(node, %{factory_id: "store_input"})
      :ok
    end

    test "is confirm-gated, and cancelling reaches nothing", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)

      assert render_click(view, "confirm_stop", %{}) =~ "Stop Relay?"

      html = render_click(view, "cancel_stop", %{})
      refute html =~ "Stop Relay?"
      assert FakeController.calls(node, {Relay, :stop}) == []
    end

    test "confirming stops it and returns to the namespace", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      render_click(view, "confirm_stop", %{})

      {:ok, _view, html} =
        view |> render_click("stop_relay", %{}) |> follow_redirect(conn, "/namespaces/default")

      assert html =~ "Relay relay_a stopped."

      assert [["default", "relay_a", %{source: :ui}]] = FakeController.calls(node, {Relay, :stop})
    end

    test "a cooperative stop says the relay finishes its in-flight work", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :stop},
        {:ok, %{id: "relay_a", stopped: :cooperative}}
      )

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "confirm_stop", %{})

      {:ok, _view, html} =
        view |> render_click("stop_relay", %{}) |> follow_redirect(conn, "/namespaces/default")

      assert html =~ "finishes its in-flight work"
    end

    test "a refused stop keeps the operator on the screen", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :stop}, FakeController.error("relay.not_running"))

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "confirm_stop", %{})

      assert render_click(view, "stop_relay", %{}) =~ "relay.not_running (test)"
    end
  end

  describe "reading cell state" do
    setup %{node: node} do
      overwatch(node, %{factory_id: "store_input"})
      :ok
    end

    test "renders the state the controller returned", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :cell_state}, {:ok, ~s({"balance":42}), 7})

      {:ok, view, _html} = live(conn, @url)
      open_section(view, "sdk-state")
      html = render_click(view, "fetch_state", %{})

      assert html =~ ~s(data-testid="state-json")
      assert html =~ "balance"
    end

    test "narrows the read to one cell as the operator fills in both", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @url)

      render_change(view, "selector_change", %{
        "selector" => %{"tasklet" => "charge", "cell_key" => "cust-9"}
      })

      render_click(view, "fetch_state", %{})

      assert [["default", "relay_a", "charge/cust-9", %{source: :ui}]] =
               FakeController.calls(node, {Relay, :cell_state})
    end

    test "no tasklet reads every cell", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      render_click(view, "fetch_state", %{})

      assert [["default", "relay_a", nil, %{source: :ui}]] =
               FakeController.calls(node, {Relay, :cell_state})
    end

    test "a cell key without a tasklet makes no read", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      open_section(view, "sdk-state")

      render_change(view, "selector_change", %{"selector" => %{"cell_key" => "cust-9"}})
      html = render_click(view, "fetch_state", %{})

      assert html =~ "name the tasklet too"
      assert FakeController.calls(node, {Relay, :cell_state}) == []
    end

    test "explains a relay that keeps no state", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :cell_state},
        FakeController.error("state.persistence_off")
      )

      {:ok, view, _html} = live(conn, @url)
      open_section(view, "sdk-state")

      html = render_click(view, "fetch_state", %{})
      assert html =~ ~s(data-testid="state-notice")
      assert html =~ "persistence off"
    end

    test "explains cells that are not held in memory", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :cell_state}, FakeController.error("state.not_resident"))

      {:ok, view, _html} = live(conn, @url)
      open_section(view, "sdk-state")

      assert render_click(view, "fetch_state", %{}) =~ "not held in memory"
    end
  end

  # The relay screen opens the shared plugin form with this relay fixed.
  defp open_attach(view),
    do: view |> element(~s([data-testid="attach-plugin-btn"])) |> render_click()
end
