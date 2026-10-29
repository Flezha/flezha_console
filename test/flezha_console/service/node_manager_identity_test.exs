defmodule FlezhaConsole.Service.NodeManagerIdentityTest do
  @moduledoc """
  The identity half of the seam: token verification, the caller context built
  from it, the door every operation is run through, the error shape, the
  enforcement posture, and the stream operations a context carries an emit pid
  for.

  Each verification gets its own token string. Verification is cached per
  token, so a second answer set under a token already asked about would never
  be heard. `FakeController.reset/1` empties the cache between tests.
  """

  use ExUnit.Case, async: false

  alias FlezhaConsole.PeerNode
  alias FlezhaConsole.Service.NodeManager

  @moduletag :distributed

  @context {Flezha.Service.Admin, :context}
  @posture {Flezha.AuthZ, :enforcement_posture}
  @cache :flezha_console_authz_cache

  setup_all do
    PeerNode.setup_controller("nm_identity_peer")
  end

  setup %{node: node} do
    FakeController.reset(node)
    %{token: unique_token()}
  end

  defp unique_token, do: "flzt_test_#{System.unique_integer([:positive])}"

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{source: :ui, principal: "ops@acme", namespace: "default", role: :ops},
      overrides
    )
  end

  # A static answer, not a closure: the peer never loads this test module, so a
  # function defined here is `:undef` there.
  defp bind(node, identity), do: FakeController.set(node, @context, {:ok, identity})

  defp refuse_context(node, code),
    do: FakeController.set(node, @context, FakeController.error(code))

  defp context_calls(node), do: FakeController.calls(node, @context)

  describe "error/1" do
    test "reads a controller error by its fields" do
      error = Flezha.Error.new("authz.role_insufficient", "no", "ask for ops")

      assert NodeManager.error({:error, error}) ==
               %{
                 code: "authz.role_insufficient",
                 class: :denied,
                 message: "no",
                 hint: "ask for ops",
                 details: %{}
               }
    end

    test "keeps the details a controller error carries, keyed by text" do
      error =
        Flezha.Error.new("plugin.option_invalid", "bad", nil, %{"option" => "url", "value" => 1})

      assert %{code: "plugin.option_invalid", details: %{"option" => "url", "value" => 1}} =
               NodeManager.error({:error, error})

      assert %{details: %{}} = NodeManager.error(:node_not_connected)
    end

    test "gives the transport conditions the same shape" do
      assert %{code: "console.node_not_connected", class: :unavailable} =
               NodeManager.error(:node_not_connected)

      assert %{code: "console.timeout", class: :unavailable} =
               NodeManager.error({:error, :timeout})

      assert %{code: "console.api_missing", class: :internal, message: message} =
               NodeManager.error({:api_missing, Flezha.Service.Relay, :list, 2})

      assert message =~ "Flezha.Service.Relay.list/2"

      assert %{code: "console.remote_error", class: :internal} =
               NodeManager.error({:remote_error, :boom})

      assert %{code: "console.unexpected", hint: nil} = NodeManager.error(:something_else)
    end

    test "denied?/1 is the refusal class and nothing else" do
      assert NodeManager.denied?(FakeController.error("authz.principal_not_bound"))
      refute NodeManager.denied?(FakeController.error("relay.not_found"))
      refute NodeManager.denied?({:error, :node_not_connected})
    end
  end

  describe "verify_token/1" do
    test "a valid token answers the door's context", %{node: node, token: token} do
      bind(node, identity())

      assert {:ok, %{principal: "ops@acme", namespace: "default", role: :ops}} =
               NodeManager.verify_token(token)

      assert [[:ui, ^token]] = context_calls(node)
    end

    test "the store's own refusals pass through", %{node: node} do
      for code <-
            ~w(authz.token_malformed authz.token_unknown authz.token_revoked authz.token_expired) do
        token = unique_token()
        refuse_context(node, code)

        assert {:error, %Flezha.Error{code: ^code}} = NodeManager.verify_token(token)
      end
    end

    test "no token is not a call at all", %{node: node} do
      before = length(context_calls(node))

      assert {:error, :no_token} = NodeManager.verify_token(nil)
      assert {:error, :no_token} = NodeManager.verify_token("")
      assert length(context_calls(node)) == before
    end
  end

  describe "verification caching" do
    test "several calls on one tick cost one verification", %{node: node, token: token} do
      bind(node, identity())

      for _ <- 1..5, do: NodeManager.caller_context(token)

      assert length(context_calls(node)) == 1
    end

    test "an authz.token_* failure is cached, so a bad token is not re-asked per call", %{
      node: node
    } do
      token = unique_token()
      refuse_context(node, "authz.token_revoked")

      for _ <- 1..3, do: NodeManager.verify_token(token)

      assert length(context_calls(node)) == 1
    end

    test "an unopened registry is not an answer about the token", %{node: node, token: token} do
      refuse_context(node, "authz.registry_unavailable")

      for _ <- 1..3, do: NodeManager.verify_token(token)

      assert length(context_calls(node)) == 3
    end

    test "eviction forces the next call to re-ask", %{node: node, token: token} do
      bind(node, identity())

      NodeManager.verify_token(token)
      NodeManager.evict_token(token)
      NodeManager.verify_token(token)

      assert length(context_calls(node)) == 2
    end
  end

  describe "caller_context/1" do
    test "a verified token binds principal, namespace and role", %{node: node, token: token} do
      bind(node, identity(%{principal: "alice", namespace: "acme", role: :admin}))

      assert NodeManager.caller_context(token) ==
               %{source: :ui, principal: "alice", namespace: "acme", role: :admin}
    end

    test "only the verified role is carried, never a list of roles", %{node: node, token: token} do
      bind(node, identity(%{roles: [:ops, :viewer]}))

      context = NodeManager.caller_context(token)

      assert context.role == :ops
      refute Map.has_key?(context, :roles)
    end

    test "an unverifiable token leaves the context unbound", %{node: node} do
      token = unique_token()
      refuse_context(node, "authz.token_expired")

      assert NodeManager.caller_context(token) == %{source: :ui}
    end

    test "no token leaves the context unbound" do
      assert NodeManager.caller_context(nil) == %{source: :ui}
      assert NodeManager.caller_context("") == %{source: :ui}
    end

    test "a value that looks like a principal is not one", %{node: node} do
      # The only input is a token, and an unverifiable one binds nothing — so a
      # principal name typed into any form can never reach the context.
      refuse_context(node, "authz.token_malformed")

      assert NodeManager.caller_context("admin@_system") == %{source: :ui}
    end
  end

  describe "refusals" do
    test "a refused call answers the controller's error untouched", %{node: node, token: token} do
      bind(node, identity())

      FakeController.set(
        node,
        {Flezha.Service.Logs, :files},
        FakeController.error("authz.principal_not_bound")
      )

      assert {:error, %Flezha.Error{code: "authz.principal_not_bound", class: :denied}} =
               NodeManager.log_files("audit", token)
    end

    test "an unanswerable verification is reported rather than called unbound", %{
      node: node,
      token: token
    } do
      refuse_context(node, "authz.registry_unavailable")

      assert {:error, %Flezha.Error{code: "authz.registry_unavailable"}} =
               NodeManager.log_stats("audit", token)

      assert {:error, %Flezha.Error{code: "authz.registry_unavailable"}} =
               NodeManager.log_tail("audit", %{}, token, self())

      assert FakeController.calls(node, {Flezha.Service.Logs, :stats}) == []
      assert FakeController.calls(node, {Flezha.Service.Logs, :tail}) == []
    end

    test "a refusal evicts the token, so a removed binding costs one call", %{
      node: node,
      token: token
    } do
      bind(node, identity())
      NodeManager.caller_context(token)
      assert length(context_calls(node)) == 1

      FakeController.set(
        node,
        {Flezha.Service.Logs, :stats},
        FakeController.error("authz.role_insufficient")
      )

      assert {:error, %Flezha.Error{class: :denied}} = NodeManager.log_stats("audit", token)

      # The cached identity is gone, so the next context is established afresh.
      NodeManager.caller_context(token)
      assert length(context_calls(node)) == 2
    end

    test "a failure that is not a refusal keeps the cached identity", %{
      node: node,
      token: token
    } do
      bind(node, identity())
      NodeManager.caller_context(token)

      FakeController.set(
        node,
        {Flezha.Service.Relay, :overwatch_state},
        FakeController.error("relay.not_found")
      )

      assert {:error, %Flezha.Error{class: :not_found}} =
               NodeManager.overwatch_state("default", "gone", token)

      NodeManager.caller_context(token)
      assert length(context_calls(node)) == 1
    end

    test "an authorized call carries the bound context last", %{node: node, token: token} do
      bind(node, identity(%{principal: "alice", namespace: "acme", role: :viewer}))

      FakeController.set(
        node,
        {Flezha.Service.Logs, :files},
        {:ok, %{files: [], unreachable: []}}
      )

      assert {:ok, %{rows: []}} = NodeManager.log_files("audit", token)

      assert [
               [
                 [kind: "audit"],
                 %{source: :ui, principal: "alice", namespace: "acme", role: :viewer}
               ]
             ] =
               FakeController.calls(node, {Flezha.Service.Logs, :files})
    end

    test "an operation is run through the door by its catalogue name", %{
      node: node,
      token: token
    } do
      bind(node, identity())

      assert {:ok, %{rows: []}} = NodeManager.log_files("audit", token)
      assert ["Logs.files"] in FakeController.calls(node, {Flezha.Service.Admin, :run})
    end

    test "an operation the door does not publish is version skew, named as called", %{
      node: node,
      token: token
    } do
      bind(node, identity())

      FakeController.set(
        node,
        {Flezha.Service.Relay, :graph},
        FakeController.error("control.unknown_function")
      )

      assert {:error, {:api_missing, Flezha.Service.Relay, :graph, 3}} =
               NodeManager.relay_graph("default", "relay_a", token)
    end

    test "a domain error passes through as the controller's own", %{node: node, token: token} do
      bind(node, identity())

      FakeController.set(
        node,
        {Flezha.Service.Logs, :files},
        FakeController.error("audit.disabled")
      )

      assert {:error, %Flezha.Error{code: "audit.disabled", class: :unavailable}} =
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

      assert [["acme", %{source: :ui}]] =
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
        {:error, {:api_missing, Flezha.Service.Namespace, :list, 1}}
      )

      assert {:error, {:api_missing, _, _, _}} = NodeManager.namespace_records(token)
      assert [] = FakeController.calls(node, {Flezha.Service.Namespace, :get})
    end
  end

  describe "stream operations" do
    test "hand each event to the emit pid, then report the operation's end", %{node: node} do
      key = {Flezha.Service.Observability, :tail}

      assert {:ok, request} = NodeManager.observability_tail(:flezha_runner, nil, self())
      assert PeerNode.eventually(fn -> FakeController.streams(node, key) == [self()] end)

      assert [["flezha_runner", %{source: :ui, emit: emit}]] = FakeController.calls(node, key)
      assert emit == self()

      FakeController.emit(node, key, %{name: :runner_connected})
      assert_receive {:flezha_emit, %{name: :runner_connected}}

      FakeController.end_stream(node, key, {:ok, :done})
      assert {:ended, {:ok, :done}} = await_end(request)
    end

    test "a refusal ends the stream and evicts the token", %{node: node, token: token} do
      bind(node, identity())
      NodeManager.caller_context(token)

      FakeController.set(
        node,
        {Flezha.Service.Logs, :tail},
        FakeController.error("authz.role_insufficient")
      )

      assert {:ok, request} = NodeManager.log_tail("audit", %{}, token, self())
      assert {:ended, {:error, %Flezha.Error{class: :denied}}} = await_end(request)

      NodeManager.caller_context(token)
      assert length(context_calls(node)) == 2
    end

    test "a message that is not the answer is not mistaken for one" do
      assert {:ok, request} = NodeManager.observability_tail(:flezha_runner, nil, self())
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

  describe "enforcement_posture/0" do
    test "the controller's own answer passes through", %{node: node} do
      for posture <- [:open, :bootstrap_pending, :enforced] do
        FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, posture)
        assert NodeManager.enforcement_posture() == posture
      end
    end

    test "a controller predating authorization is open, not broken", %{node: node} do
      FakeController.set(
        node,
        {Flezha.AuthZ, :enforcement_posture},
        {:error, {:api_missing, Flezha.AuthZ, :enforcement_posture, 0}}
      )

      assert NodeManager.enforcement_posture() == :open
    end
  end

  describe "authz_status/1" do
    test "a bound token is reported with its identity", %{node: node, token: token} do
      FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, :enforced)
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

    test "a rejected token is distinguished from no token at all", %{node: node} do
      FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, :enforced)
      refuse_context(node, "authz.token_expired")

      assert %{principal: nil, token?: true, reason: %Flezha.Error{code: "authz.token_expired"}} =
               NodeManager.authz_status(unique_token())

      assert %{principal: nil, token?: false, reason: nil} = NodeManager.authz_status(nil)
    end
  end

  describe "the identity cache" do
    test "never holds the token itself", %{node: node, token: token} do
      FakeController.set(node, @posture, :enforced)
      bind(node, identity())

      assert {:ok, _identity} = NodeManager.verify_token(token)
      assert %{principal: "ops@acme"} = NodeManager.authz_status(token)

      entries = :ets.tab2list(@cache)
      assert [_ | _] = entries
      assert :binary.match(:erlang.term_to_binary(entries), token) == :nomatch
    end

    test "a posture change shows once the cached posture expires", %{node: node, token: token} do
      FakeController.set(node, @posture, :open)
      assert %{posture: :open} = NodeManager.authz_status(token)

      FakeController.set(node, @posture, :enforced)
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
