defmodule FlezhaConsoleWeb.FlezhaTokenSettingsTest do
  @moduledoc """
  Storing a flezha token from the settings screen against the controller
  stand-in: the flash names the principal a verified token acts as, and says
  in words why one did not verify.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Admin
  alias FlezhaConsole.Accounts

  defp store(conn, token),
    do:
      put(conn, ~p"/users/settings", %{
        "action" => "update_flezha_token",
        "flezha_token" => %{"token" => token}
      })

  test "a token the controller verifies is stored and the flash names its principal", %{
    conn: conn,
    node: node,
    user: user
  } do
    token = "flzt_good_#{System.unique_integer([:positive])}"

    FakeController.set(
      node,
      {Admin, :context},
      {:ok, %{principal: "alice", namespace: "acme", role: :ops, source: :ui}}
    )

    conn = store(conn, token)

    assert Accounts.user_flezha_token(user) == token

    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
             "Calls are now made as alice (acme, ops)"
  end

  test "a token that does not verify is stored, and the flash says why in words", %{
    conn: conn,
    node: node,
    user: user
  } do
    token = "flzt_unknown_#{System.unique_integer([:positive])}"

    FakeController.set(
      node,
      {Admin, :context},
      FakeController.error("authz.token_unknown", "no such token")
    )

    conn = store(conn, token)

    assert Accounts.user_flezha_token(user) == token
    flash = Phoenix.Flash.get(conn.assigns.flash, :info)
    assert flash =~ "did not verify: no such token (authz.token_unknown)"
    refute flash =~ "%Flezha.Error"
  end
end
