defmodule FlezhaUi.FlezhaTokenTest do
  @moduledoc """
  A user's own flezha token, and the service token in `FLEZHA_TOKEN` it falls
  back to: stored, read, cleared and set from the settings page.

  Serial, because `FLEZHA_TOKEN` is the OS process's environment, which every
  test reads.
  """

  use FlezhaUiWeb.ConnCase, async: false

  import FlezhaUi.AccountsFixtures

  alias FlezhaUi.Accounts
  alias FlezhaUi.Accounts.User
  alias FlezhaUi.Repo
  alias FlezhaUi.TestEnv

  setup do
    TestEnv.put_system("FLEZHA_TOKEN", nil)
  end

  describe "a user's token" do
    setup do
      %{user: user_fixture()}
    end

    test "a stored token is read back", %{user: user} do
      {:ok, _user} = Accounts.update_user_flezha_token(user, "flz_personal")

      assert Accounts.user_flezha_token(user) == "flz_personal"
      assert Accounts.flezha_token(user) == "flz_personal"
    end

    test "the token is not stored in the clear", %{user: user} do
      {:ok, _user} = Accounts.update_user_flezha_token(user, "flz_personal")

      # Read past the field's type: a `select:` on the schema would decrypt it.
      %{rows: [[raw]]} =
        Ecto.Adapters.SQL.query!(Repo, "SELECT flezha_token FROM users WHERE id = $1", [user.id])

      assert is_binary(raw)
      refute raw =~ "flz_personal"
    end

    test "the column is never loaded by an ordinary query", %{user: user} do
      {:ok, _user} = Accounts.update_user_flezha_token(user, "flz_personal")

      reloaded = Repo.get!(User, user.id)

      assert reloaded.flezha_token == nil
      refute inspect(reloaded) =~ "flz_personal"
    end

    test "a user without a token falls back to the service token", %{user: user} do
      TestEnv.put_system("FLEZHA_TOKEN", "flz_service")

      assert Accounts.user_flezha_token(user) == nil
      assert Accounts.flezha_token(user) == "flz_service"
    end

    test "a user's own token wins over the service token", %{user: user} do
      TestEnv.put_system("FLEZHA_TOKEN", "flz_service")
      {:ok, _user} = Accounts.update_user_flezha_token(user, "flz_personal")

      assert Accounts.flezha_token(user) == "flz_personal"
    end

    test "neither token leaves the caller unbound", %{user: user} do
      assert Accounts.flezha_token(user) == nil
      assert Accounts.flezha_token(nil) == nil
    end

    test "clearing falls back to the service token", %{user: user} do
      TestEnv.put_system("FLEZHA_TOKEN", "flz_service")
      {:ok, _user} = Accounts.update_user_flezha_token(user, "flz_personal")
      {:ok, _user} = Accounts.clear_user_flezha_token(user)

      assert Accounts.user_flezha_token(user) == nil
      assert Accounts.flezha_token(user) == "flz_service"
    end

    test "a blank token clears rather than storing an empty credential", %{user: user} do
      {:ok, _user} = Accounts.update_user_flezha_token(user, "flz_personal")
      {:ok, _user} = Accounts.update_user_flezha_token(user, "   ")

      assert Accounts.user_flezha_token(user) == nil
    end

    test "surrounding whitespace is trimmed off a pasted token", %{user: user} do
      {:ok, _user} = Accounts.update_user_flezha_token(user, "  flz_personal\n")

      assert Accounts.user_flezha_token(user) == "flz_personal"
    end

    test "the scope carries the resolved token", %{user: user} do
      {:ok, _user} = Accounts.update_user_flezha_token(user, "flz_personal")

      scope = FlezhaUi.Accounts.Scope.for_user(Repo.get!(User, user.id))

      assert FlezhaUi.Accounts.Scope.flezha_token(scope) == "flz_personal"
      refute inspect(scope) =~ "flz_personal"
    end
  end

  describe "PUT /users/settings (flezha token)" do
    setup :register_and_log_in_user

    test "the settings page states that no token is stored", %{conn: conn} do
      response = conn |> get(~p"/users/settings") |> html_response(200)

      assert response =~ "Flezha token"
      assert response =~ "the service token is used"
    end

    test "storing a token round-trips without echoing it", %{conn: conn, user: user} do
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_flezha_token",
          "flezha_token" => %{"token" => "flz_secret_value"}
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Accounts.user_flezha_token(user) == "flz_secret_value"

      response =
        conn
        |> recycle()
        |> log_in_user(user)
        |> get(~p"/users/settings")
        |> html_response(200)

      # Presence is stated; the credential itself is not on the page.
      assert response =~ "Stored for you"
      refute response =~ "flz_secret_value"
    end

    test "clearing a token removes it", %{conn: conn, user: user} do
      {:ok, _user} = Accounts.update_user_flezha_token(user, "flz_secret_value")

      conn = put(conn, ~p"/users/settings", %{"action" => "clear_flezha_token"})

      assert redirected_to(conn) == ~p"/users/settings"
      assert Accounts.user_flezha_token(user) == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "cleared"
    end

    test "a blank submission clears rather than storing nothing", %{conn: conn, user: user} do
      {:ok, _user} = Accounts.update_user_flezha_token(user, "flz_secret_value")

      put(conn, ~p"/users/settings", %{
        "action" => "update_flezha_token",
        "flezha_token" => %{"token" => ""}
      })

      assert Accounts.user_flezha_token(user) == nil
    end
  end
end
