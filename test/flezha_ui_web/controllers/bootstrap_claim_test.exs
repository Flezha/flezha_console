defmodule FlezhaUiWeb.BootstrapClaimTest do
  @moduledoc """
  Claiming a pending bootstrap from the settings screen: offered only while
  the posture is `:bootstrap_pending`, and the admin token it mints stored as
  the user's own without ever being rendered.

  Against the controller stand-in, because the posture is the controller's
  answer. Each test stores a token of its own first, so the posture cached for
  one test's credential is not the next one's.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Namespace
  alias FlezhaUi.Accounts
  alias FlezhaUi.TestEnv

  @minted "flzt_minted_admin_secret"

  setup %{user: user, node: node} do
    TestEnv.put_system("FLEZHA_TOKEN", nil)

    {:ok, _user} =
      Accounts.update_user_flezha_token(user, "flzt_before_#{System.unique_integer([:positive])}")

    FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, :bootstrap_pending)
    :ok
  end

  defp claim(conn, token),
    do:
      put(conn, ~p"/users/settings", %{
        "action" => "claim_bootstrap",
        "bootstrap" => %{"token" => token}
      })

  test "the claim is offered while the bootstrap is pending", %{conn: conn} do
    html = conn |> get(~p"/users/settings") |> html_response(200)

    assert html =~ ~s(data-testid="bootstrap-claim")
    assert html =~ ~s(data-testid="bootstrap-claim-btn")
  end

  test "the claim is not offered once enforced or open", %{conn: conn, node: node, user: user} do
    for posture <- [:enforced, :open] do
      FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, posture)
      token = "flzt_#{posture}_#{System.unique_integer([:positive])}"
      {:ok, _user} = Accounts.update_user_flezha_token(user, token)

      html = conn |> get(~p"/users/settings") |> html_response(200)

      refute html =~ ~s(data-testid="bootstrap-claim")
    end
  end

  test "a claim stores the minted token as the user's own, unrendered", %{
    conn: conn,
    node: node,
    user: user
  } do
    FakeController.set(
      node,
      {Flezha.AuthZ.TokenStore, :verify},
      {:ok, %{principal: "admin-claimed", namespace: "_system", role: :admin, expires_at: :never}}
    )

    conn = claim(conn, " flzb_one_time ")

    assert [["flzb_one_time", %{source: :ui}]] =
             FakeController.calls(node, {Namespace, :bootstrap})

    assert redirected_to(conn) == ~p"/users/settings"

    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
             "admin-claimed is bound as admin@_system"

    refute Phoenix.Flash.get(conn.assigns.flash, :info) =~ @minted
    assert Accounts.user_flezha_token(user) == @minted

    FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, :enforced)

    html =
      conn |> recycle() |> log_in_user(user) |> get(~p"/users/settings") |> html_response(200)

    assert html =~ "admin-claimed"
    refute html =~ @minted
    refute html =~ ~s(data-testid="bootstrap-claim")
  end

  test "a claim that mints no token says so and stores nothing", %{
    conn: conn,
    node: node,
    user: user
  } do
    before = Accounts.user_flezha_token(user)

    FakeController.set(
      node,
      {Namespace, :bootstrap},
      {:ok, %{principal: "admin-claimed", minted_token: nil}}
    )

    conn = claim(conn, "flzb_one_time")

    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "No token was minted for it."
    assert Accounts.user_flezha_token(user) == before
  end

  test "a wrong bootstrap token is refused with its code and nothing is stored", %{
    conn: conn,
    node: node,
    user: user
  } do
    before = Accounts.user_flezha_token(user)

    FakeController.set(
      node,
      {Namespace, :bootstrap},
      {:error,
       Flezha.Error.new(
         "authz.bootstrap_token_mismatch",
         "that is not the bootstrap token",
         "cat storage/app/auth/bootstrap.token"
       )}
    )

    html = conn |> claim("flzb_wrong") |> html_response(200)

    assert html =~ "authz.bootstrap_token_mismatch"
    assert html =~ "cat storage/app/auth/bootstrap.token"
    assert Accounts.user_flezha_token(user) == before
  end

  test "a claim submitted when nothing is pending reaches nothing", %{
    conn: conn,
    node: node
  } do
    FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, :enforced)

    conn = claim(conn, "flzb_one_time")

    assert redirected_to(conn) == ~p"/users/settings"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "No bootstrap is pending"
    assert FakeController.calls(node, {Namespace, :bootstrap}) == []
  end
end
