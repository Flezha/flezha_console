defmodule FlezhaUi.Service.NodeManagerIdentityTest do
  @moduledoc """
  The identity half of the seam: token verification, the caller context built
  from it, the error shape, the enforcement posture, and the stream operations
  a context carries an emit pid for.

  Every test uses its own token string. Verification is cached per token for
  the whole VM, so a shared literal would let one test's answer be the next
  one's surprise — the same reason `FakeController.reset/1` exists.
  """

  use ExUnit.Case, async: false

  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.NodeManager

  @moduletag :distributed

  @verify {Flezha.AuthZ.TokenStore, :verify}

  setup do
    "nm_identity_peer"
    |> PeerNode.setup_controller()
    |> Map.put(:token, unique_token())
  end

  defp unique_token, do: "flzt_test_#{System.unique_integer([:positive])}"

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{principal: "ops@acme", namespace: "default", role: :ops, expires_at: :never},
      overrides
    )
  end

  # A static answer, not a closure: the peer never loads this test module, so a
  # function defined here is `:undef` there.
  defp bind(node, identity), do: FakeController.set(node, @verify, {:ok, identity})

  defp refuse_verify(node, code),
    do: FakeController.set(node, @verify, FakeController.error(code))

  defp verify_calls(node), do: FakeController.calls(node, @verify)

  describe "error/1" do
    test "reads a controller error by its fields" do
      error = Flezha.Error.new("authz.role_insufficient", "no", "ask for ops")

      assert NodeManager.error({:error, error}) ==
               %{
                 code: "authz.role_insufficient",
                 class: :denied,
                 message: "no",
                 hint: "ask for ops"
               }
    end

    test "gives the transport conditions the same shape" do
      assert %{code: "ui.node_not_connected", class: :unavailable} =
               NodeManager.error(:node_not_connected)

      assert %{code: "ui.timeout", class: :unavailable} = NodeManager.error({:error, :timeout})

      assert %{code: "ui.api_missing", class: :internal, message: message} =
               NodeManager.error({:api_missing, Flezha.Service.Relay, :list, 2})

      assert message =~ "Flezha.Service.Relay.list/2"

      assert %{code: "ui.remote_error", class: :internal} =
               NodeManager.error({:remote_error, :boom})

      assert %{code: "ui.unexpected", hint: nil} = NodeManager.error(:something_else)
    end

    test "denied?/1 is the refusal class and nothing else" do
      assert NodeManager.denied?(FakeController.error("authz.principal_not_bound"))
      refute NodeManager.denied?(FakeController.error("relay.not_found"))
      refute NodeManager.denied?({:error, :node_not_connected})
    end
  end

  describe "verify_token/1" do
    test "a valid token answers the store's identity", %{node: node, token: token} do
      bind(node, identity())

      assert {:ok, %{principal: "ops@acme", namespace: "default", role: :ops}} =
               NodeManager.verify_token(token)
    end

    test "the store's own refusals pass through", %{node: node} do
      for code <-
            ~w(authz.token_malformed authz.token_unknown authz.token_revoked authz.token_expired) do
        token = unique_token()
        refuse_verify(node, code)

        assert {:error, %Flezha.Error{code: ^code}} = NodeManager.verify_token(token)
      end
    end

    test "no token is not a call at all", %{node: node} do
      before = length(verify_calls(node))

      assert {:error, :no_token} = NodeManager.verify_token(nil)
      assert {:error, :no_token} = NodeManager.verify_token("")
      assert length(verify_calls(node)) == before
    end
  end

  describe "verification caching" do
    test "several calls on one tick cost one verification", %{node: node, token: token} do
      bind(node, identity())

      for _ <- 1..5, do: NodeManager.caller_context(token)

      assert length(verify_calls(node)) == 1
    end

    test "an authz.token_* failure is cached, so a bad token is not re-asked per call", %{
      node: node
    } do
      token = unique_token()
      refuse_verify(node, "authz.token_revoked")

      for _ <- 1..3, do: NodeManager.verify_token(token)

      assert length(verify_calls(node)) == 1
    end

    test "an unopened registry is not an answer about the token", %{node: node, token: token} do
      refuse_verify(node, "authz.registry_unavailable")

      for _ <- 1..3, do: NodeManager.verify_token(token)

      assert length(verify_calls(node)) == 3
    end

    test "the cache never outlives the token's own expiry", %{node: node, token: token} do
      # Already past: the entry is worth zero milliseconds, so it is not stored.
      expired = System.system_time(:second) - 60
      bind(node, identity(%{expires_at: expired}))

      NodeManager.verify_token(token)
      NodeManager.verify_token(token)

      assert length(verify_calls(node)) == 2
    end

    test "a transport failure is not an answer about the token", %{peer: peer, token: token} do
      PeerNode.stop(peer)

      assert {:error, :node_not_connected} = NodeManager.verify_token(token)
      # Nothing was cached, so a reachable controller answers for itself.
      assert {:error, :node_not_connected} = NodeManager.verify_token(token)
    end

    test "eviction forces the next call to re-ask", %{node: node, token: token} do
      bind(node, identity())

      NodeManager.verify_token(token)
      NodeManager.evict_token(token)
      NodeManager.verify_token(token)

      assert length(verify_calls(node)) == 2
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
      refuse_verify(node, "authz.token_expired")

      assert NodeManager.caller_context(token) == %{source: :ui}
    end

    test "no token leaves the context unbound" do
      assert NodeManager.caller_context(nil) == %{source: :ui}
      assert NodeManager.caller_context("") == %{source: :ui}
    end

    test "a value that looks like a principal is not one", %{node: node} do
      # The only input is a token, and an unverifiable one binds nothing — so a
      # principal name typed into any form can never reach the context.
      refuse_verify(node, "authz.token_malformed")

      assert NodeManager.caller_context("admin@_system") == %{source: :ui}
    end
  end

  describe "refusals" do
    test "a refused call answers the controller's error untouched", %{node: node, token: token} do
      bind(node, identity())

      FakeController.set(
        node,
        {Flezha.Service.AuditLog, :list_files},
        FakeController.error("authz.principal_not_bound")
      )

      assert {:error, %Flezha.Error{code: "authz.principal_not_bound", class: :denied}} =
               NodeManager.audit_files(token)
    end

    test "an unanswerable verification is reported rather than called unbound", %{
      node: node,
      token: token
    } do
      refuse_verify(node, "authz.registry_unavailable")

      assert {:error, %Flezha.Error{code: "authz.registry_unavailable"}} =
               NodeManager.audit_stats(token)

      assert {:error, %Flezha.Error{code: "authz.registry_unavailable"}} =
               NodeManager.audit_tail(token, self())

      assert FakeController.calls(node, {Flezha.Service.AuditLog, :stats}) == []
      assert FakeController.calls(node, {Flezha.Service.AuditLog, :tail}) == []
    end

    test "a refusal evicts the token, so a removed binding costs one call", %{
      node: node,
      token: token
    } do
      bind(node, identity())
      NodeManager.caller_context(token)
      assert length(verify_calls(node)) == 1

      FakeController.set(
        node,
        {Flezha.Service.AuditLog, :stats},
        FakeController.error("authz.role_insufficient")
      )

      assert {:error, %Flezha.Error{class: :denied}} = NodeManager.audit_stats(token)

      # The cached identity is gone, so the next context is established afresh.
      NodeManager.caller_context(token)
      assert length(verify_calls(node)) == 2
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
      assert length(verify_calls(node)) == 1
    end

    test "an authorized call carries the bound context last", %{node: node, token: token} do
      bind(node, identity(%{principal: "alice", namespace: "acme", role: :viewer}))
      FakeController.set(node, {Flezha.Service.AuditLog, :list_files}, {:ok, []})

      assert {:ok, []} = NodeManager.audit_files(token)

      assert [[%{source: :ui, principal: "alice", namespace: "acme", role: :viewer}]] =
               FakeController.calls(node, {Flezha.Service.AuditLog, :list_files})
    end

    test "a domain error passes through as the controller's own", %{node: node, token: token} do
      bind(node, identity())

      FakeController.set(
        node,
        {Flezha.Service.AuditLog, :list_files},
        FakeController.error("audit.disabled")
      )

      assert {:error, %Flezha.Error{code: "audit.disabled", class: :unavailable}} =
               NodeManager.audit_files(token)
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

      assert [[:flezha_runner, %{source: :ui, emit: emit}]] = FakeController.calls(node, key)
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
        {Flezha.Service.AuditLog, :tail},
        FakeController.error("authz.role_insufficient")
      )

      assert {:ok, request} = NodeManager.audit_tail(token, self())
      assert {:ended, {:error, %Flezha.Error{class: :denied}}} = await_end(request)

      NodeManager.caller_context(token)
      assert length(verify_calls(node)) == 2
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

    test "an unreachable controller is not reported as open", %{peer: peer} do
      PeerNode.stop(peer)

      assert {:error, :node_not_connected} = NodeManager.enforcement_posture()
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
      refuse_verify(node, "authz.token_expired")

      assert %{principal: nil, token?: true, reason: %Flezha.Error{code: "authz.token_expired"}} =
               NodeManager.authz_status(unique_token())

      assert %{principal: nil, token?: false, reason: nil} = NodeManager.authz_status(nil)
    end
  end
end
