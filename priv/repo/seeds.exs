# Seeds the dev stack's account: admin@flezha.com / admin. Run on every start
# of the dev `web` container, so it does nothing when the account exists, and
# nothing at all outside dev.
#
#     mix run --no-start priv/repo/seeds.exs

alias FlezhaConsole.Accounts
alias FlezhaConsole.Accounts.User

if Mix.env() == :dev do
  {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

  Ecto.Migrator.with_repo(FlezhaConsole.Repo, fn repo ->
    email = "admin@flezha.com"

    unless Accounts.get_user_by_email(email) do
      # The dev password is shorter than the 12 characters any real account
      # must have, so it is hashed here rather than through the changeset.
      %User{}
      |> User.email_changeset(%{email: email})
      |> Ecto.Changeset.change(hashed_password: Bcrypt.hash_pwd_salt("admin"))
      |> User.confirm_changeset()
      |> repo.insert!()

      IO.puts("Seeded the dev account: #{email} / admin")
    end
  end)
end
