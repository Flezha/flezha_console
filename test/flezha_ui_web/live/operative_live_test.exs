defmodule FlezhaUiWeb.OperativeLiveTest do
  @moduledoc """
  The operative detail screen.

  The browser suite drives attach and detach against a real controller, which
  is the only place the provider forms can be trusted. Covered here: the
  overwatch panel's shape, the entity-state reader, and the refusals — a
  controller that will not stop the operative, will not report its state, or
  has diverged from this UI's API.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.OperativeManager

  @url "/namespaces/default/operatives/op_a"

  defp overwatch(node, state) do
    FakeController.set(node, {OperativeManager, :get_overwatch_state}, {:ok, state})
  end

  describe "the overwatch panel" do
    test "renders what the controller reports about the operative", %{conn: conn, node: node} do
      overwatch(node, %{
        factory_id: "store_input",
        runner_id: "runner-a",
        kind: :stream,
        started_at: System.system_time(:millisecond) - 60_000,
        suspended: false,
        effectively_once: true,
        default_input_type: :text
      })

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "store_input"
      assert html =~ ~s(data-testid="operative-runner")
      assert html =~ "runner-a"
      assert html =~ ~s(data-testid="operative-kind")
      assert html =~ ~s(data-testid="operative-uptime")
      assert html =~ ~s(data-testid="operative-effectively-once")
    end

    test "takes the kind from the builder when it is not reported directly", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input", builder: %{kind: :workflow}})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "workflow"
    end

    test "marks a suspended operative", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input", suspended: true})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="operative-suspended")
    end

    test "renders a controller refusal instead of crashing", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {OperativeManager, :get_overwatch_state},
        {:error, :operative_not_running}
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "operative_not_running"
    end

    test "reports version skew by naming the missing call", %{conn: conn, node: node} do
      # Turning a remote `:undef` into `:api_missing` is `NodeManager`'s job and
      # is covered in `node_manager_distributed_test`; what matters here is that
      # the screen tells an operator the two have diverged rather than that
      # something merely broke.
      FakeController.set(
        node,
        {OperativeManager, :get_overwatch_state},
        {:error, {:api_missing, Flezha.Service.OperativeManager, :get_overwatch_state, 2}}
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "diverged"
      assert html =~ "get_overwatch_state/2"
    end
  end

  describe "plugin bindings" do
    test "lists the extensions the operative has subscribed", %{conn: conn, node: node} do
      overwatch(node, %{
        factory_id: "store_input",
        extensions: %{
          subs: %{on_input: [%{plugin_id: "plug_1", provider: Flezha.Plugin.OperativeStdout}]}
        }
      })

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="bindings-table")
      assert html =~ ~s(data-testid="binding-row-plug_1")
      assert html =~ "Flezha.Plugin.OperativeStdout"
      assert html =~ "on_input"
    end

    test "explains an operative with no plugins", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="no-plugins-msg")
    end

    test "detaching is confirm-gated and cancelling reaches nothing", %{conn: conn, node: node} do
      overwatch(node, %{
        factory_id: "store_input",
        extensions: %{
          subs: %{on_input: [%{plugin_id: "plug_1", provider: Flezha.Plugin.OperativeStdout}]}
        }
      })

      {:ok, view, _html} = live(conn, @url)

      html = render_click(view, "confirm_detach", %{"plugin_id" => "plug_1"})
      assert html =~ ~s(data-testid="detach-confirm-modal")

      html = render_click(view, "cancel_detach", %{})
      refute html =~ ~s(data-testid="detach-confirm-modal")
      assert FakeController.calls(node, {Flezha, :disable_plugin}) == []
    end

    test "confirming a detach reaches the controller and reports it", %{conn: conn, node: node} do
      overwatch(node, %{
        factory_id: "store_input",
        extensions: %{
          subs: %{on_input: [%{plugin_id: "plug_1", provider: Flezha.Plugin.OperativeStdout}]}
        }
      })

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "confirm_detach", %{"plugin_id" => "plug_1"})

      assert render_click(view, "detach_plugin", %{"plugin_id" => "plug_1"}) =~ "Plugin detached."
      assert FakeController.calls(node, {Flezha, :disable_plugin}) == [["plug_1"]]
    end

    test "a refused detach is reported rather than shown as success", %{conn: conn, node: node} do
      overwatch(node, %{
        factory_id: "store_input",
        extensions: %{
          subs: %{on_input: [%{plugin_id: "plug_1", provider: Flezha.Plugin.OperativeStdout}]}
        }
      })

      FakeController.set(node, {Flezha, :disable_plugin}, {:error, :not_found})

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "confirm_detach", %{"plugin_id" => "plug_1"})

      assert render_click(view, "detach_plugin", %{"plugin_id" => "plug_1"}) =~
               "Failed: :not_found"
    end
  end

  describe "stopping the operative" do
    setup %{node: node} do
      overwatch(node, %{factory_id: "store_input"})
      :ok
    end

    test "is confirm-gated, and cancelling reaches nothing", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)

      assert render_click(view, "confirm_stop", %{}) =~ "Stop Operative?"

      html = render_click(view, "cancel_stop", %{})
      refute html =~ "Stop Operative?"
      assert FakeController.calls(node, {Flezha, :stop_operative}) == []
    end

    test "confirming stops it and returns to the namespace", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      render_click(view, "confirm_stop", %{})

      assert {:error, {:live_redirect, %{to: "/namespaces/default"}}} =
               render_click(view, "stop_operative", %{})

      assert FakeController.calls(node, {Flezha, :stop_operative}) == [["default", "op_a"]]
    end

    test "a refused stop keeps the operator on the screen", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :stop_operative}, {:error, :not_running})

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "confirm_stop", %{})

      assert render_click(view, "stop_operative", %{}) =~ "Failed: :not_running"
    end
  end

  describe "reading entity state" do
    setup %{node: node} do
      overwatch(node, %{factory_id: "store_input"})
      :ok
    end

    test "renders the state the controller returned", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {OperativeManager, :get_entity_state},
        {:ok, ~s({"balance":42}), 7}
      )

      {:ok, view, _html} = live(conn, @url)
      html = render_click(view, "fetch_state", %{})

      assert html =~ ~s(data-testid="state-json")
      assert html =~ "balance"
    end

    test "narrows the selector as the operator fills it in", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)

      render_change(view, "selector_change", %{
        "selector" => %{"procedure" => "charge", "entity_key" => "cust-9"}
      })

      render_click(view, "fetch_state", %{})

      assert [["default", "op_a", %{procedure: "charge", entity_key: "cust-9"}]] =
               FakeController.calls(node, {OperativeManager, :get_entity_state})
    end

    test "explains a controller that has no state to give", %{conn: conn, node: node} do
      FakeController.set(node, {OperativeManager, :get_entity_state}, {:error, :not_found})

      {:ok, view, _html} = live(conn, @url)

      assert render_click(view, "fetch_state", %{}) =~ ~s(data-testid="state-notice")
    end
  end
end
