defmodule FlezhaUiWeb.UserSettingsControllerTest do
  use FlezhaUiWeb.ConnCase, async: true

  alias FlezhaUi.Accounts
  import FlezhaUi.AccountsFixtures

  setup :register_and_log_in_user

  describe "GET /users/settings" do
    test "renders settings page", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")
      response = html_response(conn, 200)
      assert response =~ "Settings"
    end

    test "redirects if user is not logged in" do
      conn = build_conn()
      conn = get(conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    @tag token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
    test "redirects if user is not in sudo mode", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must re-authenticate to access this page."
    end
  end

  describe "PUT /users/settings (change password form)" do
    test "updates the user password and resets tokens", %{conn: conn, user: user} do
      new_password_conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_password",
          "user" => %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "does not update password on invalid data", %{conn: conn} do
      old_password_conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_password",
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      response = html_response(old_password_conn, 200)
      assert response =~ "Settings"
      assert response =~ "should be at least 12 character(s)"
      assert response =~ "does not match password"

      assert get_session(old_password_conn, :user_token) == get_session(conn, :user_token)
    end
  end

  describe "PUT /users/settings (change email form)" do
    @tag :capture_log
    test "updates the user email", %{conn: conn, user: user} do
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_email",
          "user" => %{"email" => unique_user_email()}
        })

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "A link to confirm your email"

      assert Accounts.get_user_by_email(user.email)
    end

    test "does not update email on invalid data", %{conn: conn} do
      conn =
        put(conn, ~p"/users/settings", %{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      response = html_response(conn, 200)
      assert response =~ "Settings"
      assert response =~ "must have the @ sign and no spaces"
    end
  end

  describe "GET /users/settings/confirm-email/:token" do
    setup %{user: user} do
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{token: token, email: email}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")
      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Email changed successfully"

      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "Email change link is invalid or it has expired"
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      conn = get(conn, ~p"/users/settings/confirm-email/oops")
      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "Email change link is invalid or it has expired"

      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "PUT /users/settings (flezha token)" do
    setup do
      previous = System.get_env("FLEZHA_TOKEN")
      System.delete_env("FLEZHA_TOKEN")

      on_exit(fn ->
        if previous,
          do: System.put_env("FLEZHA_TOKEN", previous),
          else: System.delete_env("FLEZHA_TOKEN")
      end)

      :ok
    end

    test "the settings page states that no token is stored", %{conn: conn} do
      response = conn |> get(~p"/users/settings") |> html_response(200)

      assert response =~ "Flezha token"
      assert response =~ "using the service token"
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
