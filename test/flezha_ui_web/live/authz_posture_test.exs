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
  alias FlezhaUi.TestEnv

  setup %{node: node} do
    # The layout caches posture and identity briefly; a token per test keeps one
    # test's answer out of the next one's cache.
    token = "flz_posture_#{System.unique_integer([:positive])}"
    TestEnv.put_system("FLEZHA_TOKEN", token)

    %{node: node, token: token}
  end

  test "an unclaimed bootstrap is named, with the command that claims it", %{
    conn: conn,
    node: node
  } do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :bootstrap_pending)

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ "authz-bootstrap-pending"
    assert html =~ "flz auth bootstrap"
  end

  test "an enforced controller with no bound identity says calls will be refused", %{
    conn: conn,
    node: node
  } do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)
    FakeController.set(node, {TokenStore, :verify}, FakeController.error("authz.token_unknown"))

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ "authz-unbound"
    assert html =~ "will be refused"
    assert html =~ "/users/settings"
  end

  test "a rejected token states why it did not bind", %{conn: conn, node: node} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)

    FakeController.set(
      node,
      {TokenStore, :verify},
      FakeController.error("authz.token_revoked", "the token has been revoked")
    )

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ "authz-unbound"
    assert html =~ "revoked"
  end

  test "a bound principal is named in the top bar, not banner-ed", %{conn: conn, node: node} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)

    FakeController.set(
      node,
      {TokenStore, :verify},
      {:ok, %{principal: "alice", namespace: "acme", role: :ops, expires_at: :never}}
    )

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ "authz-identity"
    assert html =~ "alice"
    assert html =~ "acme"

    # Below desk width the drawer's foot names the principal instead.
    shown_at = fn testid ->
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-testid="#{testid}"]))
      |> LazyHTML.attribute("data-shell-at")
    end

    assert shown_at.("authz-identity") == ["desk"]
    assert shown_at.("drawer-principal") == ["compact phone"]

    assert html =~
             ~r/data-testid="drawer-principal".*?alice\s*<span>\/acme<\/span>\s*<span>\(ops\)/s

    refute html =~ "authz-unbound"
    refute html =~ "authz-bootstrap-pending"
  end

  test "an open controller says nothing on an ordinary screen", %{conn: conn, node: node} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :open)

    {:ok, _view, html} = live(conn, ~p"/cluster")

    refute html =~ "authz-unbound"
    refute html =~ "authz-bootstrap-pending"
  end

  test "the token itself never reaches the page", %{conn: conn, node: node, token: token} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)

    FakeController.set(
      node,
      {TokenStore, :verify},
      {:ok, %{principal: "alice", namespace: "acme", role: :ops, expires_at: :never}}
    )

    {:ok, _view, html} = live(conn, ~p"/cluster")

    refute html =~ token
  end

  test "the namespace picker offers only what the token can reach", %{conn: conn, node: node} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)
    # The controller narrows its catalog to the caller, so a token bound to
    # acme is answered acme alone.
    FakeController.set_fleet(node, namespaces: ["acme"])

    FakeController.set(
      node,
      {TokenStore, :verify},
      {:ok, %{principal: "alice", namespace: "acme", role: :ops, expires_at: :never}}
    )

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ ~s(data-testid="namespace-picker-acme")
    refute html =~ ~s(data-testid="namespace-picker-other")
  end

  test "a _system token is offered every namespace", %{conn: conn, node: node} do
    FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)
    FakeController.set_fleet(node, namespaces: ["acme", "other"])

    FakeController.set(
      node,
      {TokenStore, :verify},
      {:ok, %{principal: "root", namespace: "_system", role: :admin, expires_at: :never}}
    )

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ ~s(data-testid="namespace-picker-acme")
    assert html =~ ~s(data-testid="namespace-picker-other")
  end
end
