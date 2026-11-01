defmodule FlezhaConsole.Service.NodeManagerIdentityTest do
  @moduledoc """
  The identity half of the seam: token verification through
  `Namespace.whoami`, the bearer token every call carries instead of a caller
  context, the error shape, the enforcement posture, and the stream
  operations.

  Each verification gets its own token string. Verification is cached per
  token, so a second answer set under a token already asked about would never
  be heard. `FakeController.reset/1` empties the cache between tests.
  """

  use ExUnit.Case, async: false

  alias FlezhaConsole.FakeListener
  alias FlezhaConsole.Service.NodeManager

  @moduletag :channel

  @whoami {Flezha.Service.Namespace, :whoami}
  @cache :flezha_console_authz_cache

  setup_all do
    %{node: FakeListener.start!()}
  end

  setup %{node: node} do
    FakeController.reset(node)
    %{token: unique_token()}
  end

  defp unique_token, do: "flzt_test_#{System.unique_integer([:positive])}"

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{
        principal: "ops@acme",
        namespace: "default",
        role: :ops,
        operations: ["Logs.files"],
        posture: :enforced
      },
      overrides
    )
  end

  defp bind(node, identity), do: FakeController.set(node, @whoami, {:ok, identity})

  defp refuse_whoami(node, code),
    do: FakeController.set(node, @whoami, FakeController.error(code))

  defp whoami_calls(node), do: FakeController.calls(node, @whoami)

  describe "error/1" do
    test "reads a controller error by its fields, as the channel carried it",
         %{node: node, token: token} do
      FakeController.set(
        node,
        {Flezha.Service.Logs, :files},
        {:error,
         %{
           Flezha.Error.new("plugin.option_invalid", "bad")
           | hint: "ask for ops",
             details: %{"option" => "url", "value" => 1}
         }}
      )

      assert NodeManager.error(NodeManager.log_files("audit", token)) == %{
               code: "plugin.option_invalid",
               class: :invalid,
               message: "bad",
               hint: "ask for ops",
               details: %{"option" => "url", "value" => 1}
             }
    end

    test "gives the transport conditions the same shape" do
      assert %{code: "console.node_not_connected", class: :unavailable, details: %{}} =
               NodeManager.error(:node_not_connected)

      assert %{code: "console.timeout", class: :unavailable} =
               NodeManager.error({:error, :timeout})

      assert %{code: "console.overrun", class: :unavailable} = NodeManager.error(:overrun)
      assert %{code: "console.no_token", class: :denied} = NodeManager.error(:no_token)

      assert %{code: "console.api_missing", class: :internal, message: message} =
               NodeManager.error({:api_missing, Flezha.Service.Relay, :list, 2})

      assert message =~ "Flezha.Service.Relay.list/2"

      assert %{code: "console.remote_error", class: :internal} =
               NodeManager.error({:remote_error, :boom})

      assert %{code: "console.unexpected", hint: nil} = NodeManager.error(:something_else)
    end

    test "denied?/1 is the refusal class and nothing else", %{node: node, token: token} do
      for {code, denied?} <- [{"authz.principal_not_bound", true}, {"relay.not_found", false}] do
        FakeController.set(node, {Flezha.Service.Logs, :files}, FakeController.error(code))
        assert NodeManager.denied?(NodeManager.log_files("audit", token)) == denied?
      end

      refute NodeManager.denied?({:error, :node_not_connected})
    end
  end

  describe "verify_token/1" do
    test "whoami's answer is the identity, asked with the token as its bearer",
         %{node: node, token: token} do
      bind(node, identity())

      assert {:ok,
              %{
                principal: "ops@acme",
                namespace: "default",
                role: :ops,
                operations: ["Logs.files"],
                posture: :enforced
              }} = NodeManager.verify_token(token)

      assert [[%{token: ^token}]] = whoami_calls(node)
    end

    test "the store's own refusals pass through", %{node: node} do
      for code <-
            ~w(authz.token_malformed authz.token_unknown authz.token_revoked authz.token_expired) do
        token = unique_token()
        refuse_whoami(node, code)

        assert {:error, %{code: ^code}} = NodeManager.verify_token(token)
      end
    end

    test "no token is not a call at all", %{node: node} do
      assert {:error, :no_token} = NodeManager.verify_token(nil)
      assert {:error, :no_token} = NodeManager.verify_token("")
      assert {:error, :no_token} = NodeManager.log_files("audit", nil)

      assert whoami_calls(node) == []
      assert FakeController.calls(node, {Flezha.Service.Logs, :files}) == []
    end
  end

  describe "verification caching" do
    test "several reads on one tick cost one verification", %{node: node, token: token} do
      bind(node, identity())

      for _ <- 1..5 do
        NodeManager.verify_token(token)
        NodeManager.operations(token)
      end

      assert length(whoami_calls(node)) == 1
    end

    test "an authz.token_* failure is cached, so a bad token is not re-asked per call", %{
      node: node
    } do
      token = unique_token()
      refuse_whoami(node, "authz.token_revoked")

      for _ <- 1..3, do: NodeManager.verify_token(token)

      assert length(whoami_calls(node)) == 1
    end

    test "an unopened registry is not an answer about the token", %{node: node, token: token} do
      refuse_whoami(node, "authz.registry_unavailable")

      for _ <- 1..3, do: NodeManager.verify_token(token)

      assert length(whoami_calls(node)) == 3
    end

    test "eviction forces the next call to re-ask", %{node: node, token: token} do
      bind(node, identity())

      NodeManager.verify_token(token)
      NodeManager.evict_token(token)
      NodeManager.verify_token(token)

      assert length(whoami_calls(node)) == 2
    end
  end

  describe "the token as the caller's identity" do
    test "a call carries the token as its bearer, and no identity of the console's making",
         %{node: node, token: token} do
      FakeController.set(
        node,
        {Flezha.Service.Logs, :files},
        {:ok, %{files: [], unreachable: []}}
      )

      assert {:ok, %{rows: []}} = NodeManager.log_files("audit", token)

      assert [[%{"kind" => "audit"}, context]] =
               FakeController.calls(node, {Flezha.Service.Logs, :files})

      assert context == %{source: :http, token: token}
    end

    test "no verification precedes a call: the controller judges the token itself",
         %{node: node, token: token} do
      refuse_whoami(node, "authz.token_unknown")

      assert {:ok, _stats} = NodeManager.log_stats("audit", token)
      assert whoami_calls(node) == []
    end

    test "a value that looks like a principal is only ever a bearer token", %{node: node} do
      refuse_whoami(node, "authz.token_malformed")

      assert {:error, %{code: "authz.token_malformed"}} =
               NodeManager.verify_token("admin@_system")

      assert [[%{token: "admin@_system"} = context]] = whoami_calls(node)
      refute Map.has_key?(context, :principal)
    end
  end

  describe "refusals" do
    test "a refused call answers the controller's error", %{node: node, token: token} do
      FakeController.set(
        node,
        {Flezha.Service.Logs, :files},
        FakeController.error("authz.principal_not_bound")
      )

      assert {:error, %{code: "authz.principal_not_bound", class: :denied}} =
               NodeManager.log_files("audit", token)
    end

    test "a refusal evicts the token, so a removed binding costs one call", %{
      node: node,
      token: token
    } do
      bind(node, identity())
      NodeManager.verify_token(token)
      assert length(whoami_calls(node)) == 1

      FakeController.set(
        node,
        {Flezha.Service.Logs, :stats},
        FakeController.error("authz.role_insufficient")
      )

      assert {:error, %{class: :denied}} = NodeManager.log_stats("audit", token)

      # The cached identity is gone, so the next verification asks again.
      NodeManager.verify_token(token)
      assert length(whoami_calls(node)) == 2
    end

    test "a failure that is not a refusal keeps the cached identity", %{
      node: node,
      token: token
    } do
      bind(node, identity())
      NodeManager.verify_token(token)

      FakeController.set(
        node,
        {Flezha.Service.Relay, :overwatch_state},
        FakeController.error("relay.not_found")
      )

      assert {:error, %{class: :not_found}} =
               NodeManager.overwatch_state("default", "gone", token)

      NodeManager.verify_token(token)
      assert length(whoami_calls(node)) == 1
    end

    test "an operation is run through the door by its catalogue name", %{
      node: node,
      token: token
    } do
      assert {:ok, %{rows: []}} = NodeManager.log_files("audit", token)
      assert ["Logs.files"] in FakeController.calls(node, {Flezha.Service.Admin, :run})
    end

    test "an operation the door does not publish is version skew, named as called", %{
      node: node,
      token: token
    } do
      FakeController.set(
        node,
        {Flezha.Service.Relay, :graph},
        FakeController.error("control.unknown_function")
      )

      assert {:error, {:api_missing, Flezha.Service.Relay, :graph, 3}} =
               NodeManager.relay_graph("default", "relay_a", token)
    end

    test "a domain error passes through as the controller's own", %{node: node, token: token} do
      FakeController.set(
        node,
        {Flezha.Service.Logs, :files},
        FakeController.error("audit.disabled")
      )

      assert {:error, %{code: "audit.disabled", class: :unavailable}} =
               NodeManager.log_files("audit", token)
    end
  end

  describe "namespace_records/1" do
    test "a caller the full listing refuses is answered with its own record", %{
      node: node,
      token: token
    } do
      bind(node, identity(%{namespace: "acme"}))

      FakeController.set(
        node,
        {Flezha.Service.Namespace, :list},
        FakeController.error("authz.namespace_mismatch")
      )

      FakeController.set(
        node,
        {Flezha.Service.Namespace, :get},
        {:ok, %{name: "acme", quotas: %{max_relays: 5}}}
      )

      assert {:ok, [%{name: "acme"}]} = NodeManager.namespace_records(token)

      assert [["acme", %{token: ^token}]] =
               FakeController.calls(node, {Flezha.Service.Namespace, :get})
    end

    test "a failure that is not a refusal is reported, not papered over", %{
      node: node,
      token: token
    } do
      bind(node, identity(%{namespace: "acme"}))

      FakeController.set(
        node,
        {Flezha.Service.Namespace, :list},
        FakeController.error("control.unknown_function")
      )

      assert {:error, {:api_missing, _, _, _}} = NodeManager.namespace_records(token)
      assert [] = FakeController.calls(node, {Flezha.Service.Namespace, :get})
    end
  end

  describe "stream operations" do
    test "hand each event to the emit pid, then report the operation's end",
         %{node: node, token: token} do
      key = {Flezha.Service.Observability, :tail}

      assert {:ok, request} = NodeManager.observability_tail(:flezha_runner, token, self())
      assert FakeController.eventually(fn -> FakeController.streams(node, key) != [] end)

      assert [["flezha_runner", %{token: ^token, emit: emit}]] = FakeController.calls(node, key)
      assert is_pid(emit)

      FakeController.emit(node, key, %{name: :runner_connected, metadata: %{namespace: "acme"}})
      assert_receive {:flezha_emit, %{name: :runner_connected, metadata: %{namespace: "acme"}}}

      FakeController.end_stream(node, key, {:ok, :done})
      assert {:ended, {:ok, "done"}} = await_end(request)
    end

    test "a refusal ends the stream and evicts the token", %{node: node, token: token} do
      bind(node, identity())
      NodeManager.verify_token(token)

      FakeController.set(
        node,
        {Flezha.Service.Logs, :tail},
        FakeController.error("authz.role_insufficient")
      )

      assert {:ok, request} = NodeManager.log_tail("audit", %{}, token, self())
      assert {:ended, {:error, %{class: :denied}}} = await_end(request)

      NodeManager.verify_token(token)
      assert length(whoami_calls(node)) == 2
    end

    test "without a token no stream is opened", %{node: node} do
      assert {:error, :no_token} = NodeManager.log_tail("audit", %{}, nil, self())
      assert FakeController.calls(node, {Flezha.Service.Logs, :tail}) == []
    end

    test "a message that is not the answer is not mistaken for one", %{token: token} do
      assert {:ok, request} = NodeManager.observability_tail(:flezha_runner, token, self())
      assert :no_response = NodeManager.stream_result({:flezha_emit, :x}, request)
    end
  end

  defp await_end(request) do
    receive do
      message ->
        case NodeManager.stream_result(message, request) do
          :no_response -> await_end(request)
          ended -> ended
        end
    after
      5_000 -> flunk("the stream never answered")
    end
  end

  describe "authz_status/1" do
    test "a bound token is reported with its identity and posture", %{node: node, token: token} do
      bind(node, identity(%{principal: "alice", namespace: "_system", role: :admin}))

      assert %{
               posture: :enforced,
               principal: "alice",
               namespace: "_system",
               role: :admin,
               token?: true,
               reason: nil
             } = NodeManager.authz_status(token)
    end

    test "each posture whoami answers is the one reported", %{node: node} do
      for posture <- [:open, :bootstrap_pending, :enforced] do
        bind(node, identity(%{posture: posture}))
        assert %{posture: ^posture} = NodeManager.authz_status(unique_token())
      end
    end

    test "a rejected token is distinguished from no token at all", %{node: node} do
      refuse_whoami(node, "authz.token_expired")

      assert %{principal: nil, token?: true, reason: %{code: "authz.token_expired"}} =
               NodeManager.authz_status(unique_token())

      assert %{principal: nil, posture: nil, token?: false, reason: nil} =
               NodeManager.authz_status(nil)
    end
  end

  describe "operations/1" do
    test "an enforced posture grants what whoami lists; an open one renders everything",
         %{node: node} do
      bind(node, identity(%{operations: ["Relay.stop"]}))
      assert NodeManager.operations(unique_token()) == ["Relay.stop"]

      bind(node, identity(%{posture: :open}))
      assert NodeManager.operations(unique_token()) == nil
    end
  end

  describe "the identity cache" do
    test "never holds the token itself", %{node: node, token: token} do
      bind(node, identity())

      assert {:ok, _identity} = NodeManager.verify_token(token)
      assert %{principal: "ops@acme"} = NodeManager.authz_status(token)

      entries = :ets.tab2list(@cache)
      assert [_ | _] = entries
      assert :binary.match(:erlang.term_to_binary(entries), token) == :nomatch
    end

    test "a posture change shows once the cached answers expire", %{node: node, token: token} do
      bind(node, identity(%{posture: :open}))
      assert %{posture: :open} = NodeManager.authz_status(token)

      bind(node, identity(%{posture: :enforced}))
      assert %{posture: :open} = NodeManager.authz_status(token)

      expire_cache()
      assert %{posture: :enforced} = NodeManager.authz_status(token)
    end
  end

  # Moves every entry's expiry, an absolute monotonic time, into the past.
  defp expire_cache do
    past = System.monotonic_time(:millisecond) - 1

    for {key, _value, _expires_at} <- :ets.tab2list(@cache),
        do: :ets.update_element(@cache, key, {3, past})
  end
end
