defmodule FlezhaConsole.Service.NodeManagerChannelTest do
  @moduledoc """
  How the channel's answers are read into the closed set of errors.

  `control.unknown_function` matters most: it is the exact signal that this UI
  and the controller have diverged, and the whole point of normalising it is
  that the next divergence shows up as a message naming the missing function
  instead of a crashed LiveView.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FlezhaConsole.FakeListener
  alias FlezhaConsole.Service.NodeManager

  @moduletag :channel
  @token "flzt_t"

  setup_all do
    %{node: FakeListener.start!()}
  end

  setup %{node: node} do
    FakeController.reset(node)
    :ok
  end

  describe "version skew" do
    test "an operation the controller does not publish is api_missing, with the arity called",
         %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Admin, :run},
        FakeController.error("control.unknown_function")
      )

      log =
        capture_log(fn ->
          assert {:error, {:api_missing, Flezha.Service.Relay, :stop, 3}} =
                   NodeManager.stop_relay("default", "r1", @token)
        end)

      assert log =~ "diverged"
      assert log =~ "Flezha.Service.Relay.stop/3"
    end
  end

  describe "an answer in time" do
    test "the controller's control.timeout is a timeout", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :stop},
        FakeController.error("control.timeout")
      )

      assert {:error, :timeout} = NodeManager.stop_relay("default", "r1", @token)
    end

    test "a call whose own deadline passes is a timeout", %{node: node} do
      FakeController.close_gate(node, :slow)
      FakeController.set(node, {Flezha.Service.Relay, :call}, {:gated, :slow, {:ok, "late", %{}}})

      # A deadline already passed leaves the console its margin alone to wait.
      deadline_ms = 50 - NodeManager.call_timeout(0)

      assert {:error, :timeout} =
               NodeManager.call_relay(
                 "default",
                 "r1",
                 "x",
                 "in",
                 [deadline_ms: deadline_ms],
                 @token
               )

      FakeController.open_gate(node, :slow)
    end
  end

  describe "errors the controller answers" do
    test "a domain failure is its error, read by its fields", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :stop},
        FakeController.error("relay.not_found")
      )

      assert {:error, %{code: "relay.not_found", class: :not_found, message: _, details: %{}}} =
               NodeManager.stop_relay("default", "r1", @token)
    end

    test "a refusal is denied, never a remote error", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :stop},
        FakeController.error("authz.role_insufficient")
      )

      assert {:error, %{class: :denied, code: "authz.role_insufficient"}} =
               NodeManager.stop_relay("default", "r1", @token)
    end

    test "a body that is neither an answer nor an error is a remote error", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :stop},
        {:raw, 502, "<html>bad gateway</html>"}
      )

      assert {:error, {:remote_error, {502, "<html>bad gateway</html>"}}} =
               NodeManager.stop_relay("default", "r1", @token)
    end
  end

  describe "a name the console has no atom for" do
    test "a source listed as text is tailed, enabled and disabled by that text", %{node: node} do
      source = "a_source_#{System.unique_integer([:positive])}"

      assert {:ok, _request} = NodeManager.observability_tail(source, @token, self())
      assert {:ok, _applied} = NodeManager.enable_source(source, @token)
      assert {:ok, _applied} = NodeManager.disable_source(source, @token)

      assert FakeController.eventually(fn ->
               match?(
                 [[^source, _ctx]],
                 FakeController.calls(node, {Flezha.Service.Observability, :tail})
               )
             end)

      assert [[^source, _ctx]] =
               FakeController.calls(node, {Flezha.Service.Observability, :enable_source})
    end
  end

  describe "the request" do
    test "carries the operation in its route, its arguments as JSON and the token as bearer",
         %{node: node} do
      NodeManager.relay_list("default", @token, limit: 2, filter: [ids: ["r1"]])

      assert [["default", %{"limit" => 2, "filter" => %{"ids" => ["r1"]}}, %{token: @token}]] =
               FakeController.calls(node, {Flezha.Service.Relay, :list})
    end
  end
end

defmodule FlezhaConsole.Service.NodeManagerDataPlaneTest do
  @moduledoc """
  The two data-plane reads the topology graph is built on.

  The interesting half is the observability query: it answers
  `observability.disabled` on a controller with the subsystem switched off,
  and that has to stay distinguishable from a transport failure so the graph
  can render the stall banner as absent rather than broken.
  """

  use ExUnit.Case, async: false

  alias FlezhaConsole.FakeListener
  alias FlezhaConsole.Service.NodeManager

  @moduletag :channel

  setup_all do
    %{node: FakeListener.start!()}
  end

  setup %{node: node} do
    FakeController.reset(node)
    :ok
  end

  test "the liveness snapshot is passed through as the controller produced it", %{node: node} do
    # Node names cross the channel as text.
    snapshot = %{
      channels: [%{runner_id: "runner-a", name: :chan_a, io_in_received: 7}],
      relays: [
        FakeController.relay_counters("relay_a", %{
          io_in_received: 9,
          forwarded: 8,
          filtered_nil: 1,
          namespace: "pass",
          node: "flezha@node-a"
        })
      ],
      unreachable: ["flezha@node-b"]
    }

    FakeController.set(node, {Flezha.Service.Controller, :liveness_counters}, {:ok, snapshot})

    assert NodeManager.liveness_snapshot("flzt_t", filter: [relays: [{"pass", "relay_a"}]]) ==
             {:ok, snapshot}
  end

  test "reads of the same counters with the same token are answered once", %{node: node} do
    FlezhaConsole.TestEnv.put_app(:liveness_ttl_ms, 60_000)
    snapshot = %{channels: [], relays: [], unreachable: []}
    FakeController.set(node, {Flezha.Service.Controller, :liveness_counters}, {:ok, snapshot})
    opts = [filter: [relays: [{"shared", "relay_#{System.unique_integer([:positive])}"}]]]

    assert {:ok, ^snapshot} = NodeManager.liveness_snapshot("flzt_t", opts)
    assert {:ok, ^snapshot} = NodeManager.liveness_snapshot("flzt_t", opts)

    assert [[%{"filter" => %{"relays" => [["shared", _relay]]}}, _ctx]] =
             FakeController.calls(node, {Flezha.Service.Controller, :liveness_counters})

    # Other relays are another read.
    NodeManager.liveness_snapshot("flzt_t", filter: [relays: [{"shared", "another"}]])

    assert length(FakeController.calls(node, {Flezha.Service.Controller, :liveness_counters})) ==
             2
  end

  test "a failed counters read is not kept", %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Controller, :liveness_counters},
      FakeController.error("controller.timeout")
    )

    opts = [filter: [relays: [{"failed", "relay_#{System.unique_integer([:positive])}"}]]]

    assert {:error, _reason} = NodeManager.liveness_snapshot("flzt_t", opts)
    assert {:error, _reason} = NodeManager.liveness_snapshot("flzt_t", opts)

    assert length(FakeController.calls(node, {Flezha.Service.Controller, :liveness_counters})) ==
             2
  end

  test "the observability query carries the operator's token and answers every controller",
       %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Observability, :query},
      FakeController.rows([%{name: :stall, node: :"flezha@node-a", at_us: 1}], ["flezha@node-b"])
    )

    assert {:ok,
            %{rows: [%{name: :stall, node: "flezha@node-a"}], unreachable: ["flezha@node-b"]}} =
             NodeManager.observability_query(%{source: :flezha_health, limit: 20}, "flzt_t")

    assert [[%{"source" => "flezha_health", "limit" => 20}, %{token: "flzt_t"}]] =
             FakeController.calls(node, {Flezha.Service.Observability, :query})
  end

  test "a disabled observability subsystem answers its own error, untouched", %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Observability, :query},
      FakeController.error("observability.disabled")
    )

    assert {:error, %{code: "observability.disabled"}} =
             NodeManager.observability_query(%{source: :flezha_health}, "flzt_t")
  end

  test "one controller's status row is picked out of every controller's", %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Controller, :status},
      FakeController.rows([
        FakeController.status_row("node-a"),
        FakeController.status_row("node-b", %{durability_posture: :remote_tier})
      ])
    )

    assert {:ok, %{node: "flezha@node-b", durability_posture: :remote_tier}} =
             "flzt_t"
             |> NodeManager.controller_status()
             |> NodeManager.controller_row("flezha@node-b")
  end

  test "a controller that did not answer is that error, not an empty row", %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Controller, :status},
      FakeController.rows([FakeController.status_row("node-a")], ["flezha@node-b"])
    )

    answer = NodeManager.controller_status("flzt_t")

    assert NodeManager.controller_row(answer, "flezha@node-b") ==
             {:error, {:controller_unreachable, "flezha@node-b"}}

    assert NodeManager.error({:controller_unreachable, "flezha@node-b"}).message ==
             "flezha@node-b did not answer, so its facts could not be read."

    assert NodeManager.unreachable([answer]) == ["flezha@node-b"]
  end

  test "a refused status is that refusal for the chosen controller too", %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Controller, :status},
      FakeController.error("authz.role_insufficient")
    )

    assert {:error, %{class: :denied}} =
             "flzt_t"
             |> NodeManager.controller_status()
             |> NodeManager.controller_row("flezha@node-a")
  end
end
