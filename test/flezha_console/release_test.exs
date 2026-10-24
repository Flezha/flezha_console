defmodule FlezhaConsole.ReleaseTest do
  @moduledoc """
  The admin account a release sets up from its environment: missing, it is
  created; with a password that drifted from the stored one, it is reset; with
  the right one, it is left alone so its sessions survive.
  """

  use FlezhaConsole.DataCase, async: true

  import FlezhaConsole.AccountsFixtures

  alias FlezhaConsole.Accounts
  alias FlezhaConsole.Release

  @password "a stored admin password"
  @rotated "a rotated admin password"

  test "creates the admin, which can log in at once" do
    email = unique_user_email()

    assert :ok = Release.ensure_admin(email, @password)
    assert Accounts.get_user_by_email_and_password(email, @password)
  end

  test "resets a password that no longer matches" do
    email = unique_user_email()
    :ok = Release.ensure_admin(email, @password)

    assert :ok = Release.ensure_admin(email, @rotated)
    assert Accounts.get_user_by_email_and_password(email, @rotated)
    refute Accounts.get_user_by_email_and_password(email, @password)
  end

  test "leaves an admin that already logs in with it, sessions included" do
    email = unique_user_email()
    :ok = Release.ensure_admin(email, @password)
    token = email |> Accounts.get_user_by_email() |> Accounts.generate_user_session_token()

    assert :ok = Release.ensure_admin(email, @password)
    assert Accounts.get_user_by_session_token(token)
  end

  test "refuses a password the account rules reject" do
    assert_raise RuntimeError, ~r/could not set up/, fn ->
      Release.ensure_admin(unique_user_email(), "short")
    end
  end
end
