# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     FlezhaUi.Repo.insert!(%FlezhaUi.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Dev seed user
alias FlezhaUi.Accounts

dev_email = "dev@flezha.local"

unless Accounts.get_user_by_email(dev_email) do
  {:ok, user} = Accounts.register_user(%{email: dev_email})

  user
  |> Accounts.User.password_changeset(%{password: "dev_password_123"})
  |> FlezhaUi.Repo.update!()

  # Confirm the user so magic-link guard doesn't block password login
  user
  |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
  |> FlezhaUi.Repo.update!()

  IO.puts("Seeded dev user: #{dev_email} / dev_password_123")
end
