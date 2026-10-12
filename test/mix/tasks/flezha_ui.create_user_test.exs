defmodule Mix.Tasks.FlezhaUi.CreateUserTest do
  use FlezhaUi.DataCase, async: false

  import FlezhaUi.AccountsFixtures

  alias FlezhaUi.Accounts
  alias Mix.Tasks.FlezhaUi.CreateUser

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "creates a confirmed account that logs in with its password" do
    email = unique_user_email()
    CreateUser.run([email, "--password", "a long enough password"])

    assert_received {:mix_shell, :info, ["Created " <> _]}
    user = Accounts.get_user_by_email_and_password(email, "a long enough password")
    assert user.confirmed_at
  end

  test "refuses a password shorter than 12 characters" do
    email = unique_user_email()

    assert_raise Mix.Error, ~r/password should be at least 12 character/, fn ->
      CreateUser.run([email, "--password", "short"])
    end

    refute Accounts.get_user_by_email(email)
  end

  test "refuses an email that already has an account" do
    %{email: email} = user_fixture()

    assert_raise Mix.Error, ~r/email has already been taken/, fn ->
      CreateUser.run([email, "--password", "a long enough password"])
    end
  end

  test "states its usage without an email" do
    assert_raise Mix.Error, ~r/usage: mix flezha_ui.create_user/, fn -> CreateUser.run([]) end
  end
end
