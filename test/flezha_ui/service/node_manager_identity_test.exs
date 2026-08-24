defmodule FlezhaUi.Service.NodeManagerIdentityTest do
  @moduledoc """
  The identity half of the seam: token verification, the caller context built
  from it, the refusal shape, and the enforcement posture.

  Every test uses its own token string. Verification is cached per token for
  the whole VM, so a shared literal would let one test's answer be the next
  one's surprise — the same reason `FakeController.reset/1` exists.
  """

  use ExUnit.Case, async: false

  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.NodeManager

  @moduletag :distributed

  setup do
    "nm_identity_peer"
    |> PeerNode.setup_controller()
    |> Map.put(:token, unique_token())
  end

  defp unique_token, do: "flz_test_#{System.unique_integer([:positive])}"

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{principal: "ops@acme", namespace: "default", role: :operator, expires_at: :never},
      overrides
    )
  end

  # A static answer, not a closure: the peer never loads this test module, so a
  # function defined here is `:undef` there.
  defp bind(node, identity) do
    FakeController.set(node, {Flezha.AuthZ.TokenStore, :verify}, {:ok, identity})
  end

  defp verify_calls(node), do: FakeController.calls(node, {Flezha.AuthZ.TokenStore, :verify})

  describe "verify_token/1" do
    test "a valid token answers the store's identity", %{node: node, token: token} do
      bind(node, identity())

      assert {:ok, %{principal: "ops@acme", namespace: "default", role: :operator}} =
               NodeManager.verify_token(token)
    end

    test "the store's own refusals pass through", %{node: node} do
      for reason <- [:malformed, :unknown, :token_revoked, :token_expired] do
        token = unique_token()
        FakeController.set(node, {Flezha.AuthZ.TokenStore, :verify}, {:error, reason})

        assert {:error, ^reason} = NodeManager.verify_token(token)
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

    test "a refusal is cached too, so a bad token is not re-asked per call", %{node: node} do
      token = unique_token()
      FakeController.set(node, {Flezha.AuthZ.TokenStore, :verify}, {:error, :token_revoked})

      for _ <- 1..3, do: NodeManager.verify_token(token)

      assert length(verify_calls(node)) == 1
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

    test "an unverifiable token leaves the context unbound", %{node: node} do
      token = unique_token()
      FakeController.set(node, {Flezha.AuthZ.TokenStore, :verify}, {:error, :token_expired})

      assert NodeManager.caller_context(token) == %{source: :ui}
    end

    test "no token leaves the context unbound" do
      assert NodeManager.caller_context(nil) == %{source: :ui}
      assert NodeManager.caller_context("") == %{source: :ui}
    end

    test "a value that looks like a principal is not one", %{node: node} do
      # The only input is a token, and an unverifiable one binds nothing — so a
      # principal name typed into any form can never reach the context.
      FakeController.set(node, {Flezha.AuthZ.TokenStore, :verify}, {:error, :malformed})

      assert NodeManager.caller_context("admin@_system") == %{source: :ui}
    end
  end

  describe "refusals" do
    test "a refused call keeps its own shape", %{node: node, token: token} do
      bind(node, identity())

      FakeController.set(
        node,
        {Flezha.Service.AuditLog, :list_files},
        {:error, {:forbidden, :principal_not_bound}}
      )

      assert {:error, {:forbidden, :principal_not_bound}} = NodeManager.audit_files(token)
    end

    test "a refusal evicts the token, so a revocation costs one call", %{
      node: node,
      token: token
    } do
      bind(node, identity())
      NodeManager.caller_context(token)
      assert length(verify_calls(node)) == 1

      FakeController.set(
        node,
        {Flezha.Service.AuditLog, :stats},
        {:error, {:forbidden, :role_insufficient}}
      )

      assert {:error, {:forbidden, :role_insufficient}} = NodeManager.audit_stats(token)

      # The cached identity is gone, so the next context is established afresh.
      NodeManager.caller_context(token)
      assert length(verify_calls(node)) == 2
    end

    test "an authorized call carries the bound context", %{node: node, token: token} do
      bind(node, identity(%{principal: "alice", namespace: "acme", role: :viewer}))
      FakeController.set(node, {Flezha.Service.AuditLog, :list_files}, {:ok, []})

      assert {:ok, []} = NodeManager.audit_files(token)

      assert [[%{source: :ui, principal: "alice", namespace: "acme", role: :viewer}]] =
               FakeController.calls(node, {Flezha.Service.AuditLog, :list_files})
    end

    test "a domain error is not turned into a refusal", %{node: node, token: token} do
      bind(node, identity())

      FakeController.set(
        node,
        {Flezha.Service.AuditLog, :list_files},
        {:error, :audit_log_disabled}
      )

      assert {:error, :audit_log_disabled} = NodeManager.audit_files(token)
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
      FakeController.set(node, {Flezha.AuthZ.TokenStore, :verify}, {:error, :token_expired})

      assert %{principal: nil, token?: true, reason: :token_expired} =
               NodeManager.authz_status(unique_token())

      assert %{principal: nil, token?: false, reason: nil} = NodeManager.authz_status(nil)
    end
  end

  describe "token scope" do
    test "a _system token reaches everything", %{node: node, token: token} do
      bind(node, identity(%{namespace: "_system"}))

      assert NodeManager.token_scope(token) == :all
      assert NodeManager.scope_namespaces(["a", "b"], :all) == ["a", "b"]
    end

    test "a namespace-scoped token reaches its own namespace", %{node: node, token: token} do
      bind(node, identity(%{namespace: "acme"}))

      assert NodeManager.token_scope(token) == {:namespace, "acme"}
      assert NodeManager.scope_namespaces(["acme", "other"], {:namespace, "acme"}) == ["acme"]
    end

    test "an unbound caller is not narrowed by the UI", %{node: node} do
      FakeController.set(node, {Flezha.AuthZ.TokenStore, :verify}, {:error, :unknown})

      assert NodeManager.token_scope(unique_token()) == :unbound
      assert NodeManager.scope_namespaces(["a"], :unbound) == ["a"]
    end
  end
end
