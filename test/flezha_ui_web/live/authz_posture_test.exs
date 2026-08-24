defmodule FlezhaUiWeb.AuthzPostureTest do
  @moduledoc """
  The posture the application layout states on every screen.

  Lives at this layer because the states worth asserting — an unclaimed
  bootstrap, a revoked token — are ones a live controller will not be put into
  on demand.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.AuthZ
  alias Flezha.AuthZ.TokenStore

  setup %{node: node} do
    # The layout caches posture and identity briefly; a token per test keeps one
    # test's answer out of the next one's cache.
    token = "flz_posture_#{System.unique_integer([:positive])}"
    System.put_env("FLEZHA_TOKEN", token)
    on_exit(fn -> System.delete_env("FLEZHA_TOKEN") end)

    %{node: node, token: token}
  end

  test "an unclaimed bootstrap is named, with the command that claims it", %{
    conn: conn,
    node: node
  } do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :bootstrap_pending)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "authz-bootstrap-pending"
    assert html =~ "flz auth bootstrap"
  end

  test "an enforced controller with no bound identity says calls will be refused", %{
    conn: conn,
    node: node
  } do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)
    FakeController.set(node, {TokenStore, :verify}, {:error, :unknown})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "authz-unbound"
    assert html =~ "will be refused"
    assert html =~ "/users/settings"
  end

  test "a rejected token states why it did not bind", %{conn: conn, node: node} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)
    FakeController.set(node, {TokenStore, :verify}, {:error, :token_revoked})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "authz-unbound"
    assert html =~ "revoked"
  end

  test "a bound principal is named in the top bar, not banner-ed", %{conn: conn, node: node} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)

    FakeController.set(
      node,
      {TokenStore, :verify},
      {:ok, %{principal: "alice", namespace: "acme", role: :operator, expires_at: :never}}
    )

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "authz-identity"
    assert html =~ "alice"
    assert html =~ "acme"
    refute html =~ "authz-unbound"
    refute html =~ "authz-bootstrap-pending"
  end

  test "an open controller says nothing on an ordinary screen", %{conn: conn, node: node} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :open)

    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "authz-unbound"
    refute html =~ "authz-bootstrap-pending"
  end

  test "the token itself never reaches the page", %{conn: conn, node: node, token: token} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)

    FakeController.set(
      node,
      {TokenStore, :verify},
      {:ok, %{principal: "alice", namespace: "acme", role: :operator, expires_at: :never}}
    )

    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ token
  end

  test "the namespace switcher offers only what the token can reach", %{conn: conn, node: node} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)
    FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["acme", "other"]})

    FakeController.set(
      node,
      {TokenStore, :verify},
      {:ok, %{principal: "alice", namespace: "acme", role: :operator, expires_at: :never}}
    )

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "topology-namespace-scope"
    assert html =~ "scoped to acme"
    refute html =~ ">other<"
  end

  test "a _system token is offered every namespace", %{conn: conn, node: node} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)
    FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["acme", "other"]})

    FakeController.set(
      node,
      {TokenStore, :verify},
      {:ok, %{principal: "root", namespace: "_system", role: :admin, expires_at: :never}}
    )

    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "topology-namespace-scope"
    assert html =~ ">acme<" or html =~ "acme"
    assert html =~ "other"
  end
end
