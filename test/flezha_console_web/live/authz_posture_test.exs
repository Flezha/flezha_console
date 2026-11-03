defmodule FlezhaConsoleWeb.AuthzPostureTest do
  @moduledoc """
  The posture the application layout states on every screen, as the token's
  `whoami` answers it.

  Lives at this layer because the states worth asserting — an unclaimed
  bootstrap, a revoked token — are ones a live controller will not be put into
  on demand.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Namespace
  alias FlezhaConsole.Accounts
  alias FlezhaConsole.TestEnv

  defp whoami(node, answer), do: FakeController.set(node, {Namespace, :whoami}, answer)

  defp identity(overrides),
    do:
      {:ok,
       Map.merge(
         %{principal: "alice", namespace: "acme", role: :ops, operations: [], posture: :enforced},
         overrides
       )}

  test "an unclaimed bootstrap is named, with the command that claims it", %{
    conn: conn,
    node: node
  } do
    whoami(node, identity(%{posture: :bootstrap_pending}))

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ "authz-bootstrap-pending"
    assert html =~ "flz auth bootstrap &lt; storage/app/auth/bootstrap.token"
  end

  test "a token that binds no identity says every call is refused", %{conn: conn, node: node} do
    whoami(node, FakeController.error("authz.token_unknown"))

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ "authz-unbound"
    assert html =~ "is refused"
    assert html =~ "/users/settings"
  end

  test "a rejected token states why it did not bind", %{conn: conn, node: node} do
    whoami(node, FakeController.error("authz.token_revoked", "the token has been revoked"))

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ "authz-unbound"
    assert html =~ "revoked"
  end

  test "without a token, the console says it needs one and asks the controller nothing", %{
    conn: conn,
    node: node,
    user: user
  } do
    {:ok, _user} = Accounts.clear_user_flezha_token(user)
    TestEnv.put_system("FLEZHA_TOKEN", nil)
    TestEnv.put_system("FLEZHA_TOKEN_FILE", nil)

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert text_of(html, ~s([data-testid="authz-unbound"])) =~
             "needs a flezha token to reach the controller"

    assert html =~ "/users/settings"
    assert FakeController.calls(node, {Namespace, :whoami}) == []
    assert FakeController.calls(node, {Flezha.Service.Admin, :run}) == []
  end

  test "a bound principal is named in the top bar, not banner-ed", %{conn: conn, node: node} do
    whoami(node, identity(%{}))

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
    whoami(node, identity(%{posture: :open}))

    {:ok, _view, html} = live(conn, ~p"/cluster")

    refute html =~ "authz-unbound"
    refute html =~ "authz-bootstrap-pending"
  end

  test "the token itself never reaches the page", %{conn: conn, node: node, user: user} do
    whoami(node, identity(%{}))

    {:ok, _view, html} = live(conn, ~p"/cluster")

    refute html =~ Accounts.user_flezha_token(user)
  end

  test "the namespace picker offers only what the token can reach", %{conn: conn, node: node} do
    # The controller narrows its catalog to the caller, so a token bound to
    # acme is answered acme alone.
    FakeController.set_fleet(node, namespaces: ["acme"])
    whoami(node, identity(%{}))

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ ~s(data-testid="namespace-picker-acme")
    refute html =~ ~s(data-testid="namespace-picker-other")
  end

  test "a _system token is offered every namespace", %{conn: conn, node: node} do
    FakeController.set_fleet(node, namespaces: ["acme", "other"])
    whoami(node, identity(%{principal: "root", namespace: "_system", role: :admin}))

    {:ok, _view, html} = live(conn, ~p"/cluster")

    assert html =~ ~s(data-testid="namespace-picker-acme")
    assert html =~ ~s(data-testid="namespace-picker-other")
  end
end
