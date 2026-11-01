# Makes and removes console users for the browser suite, in the dev stack's
# console database. Emails and passwords arrive as arguments, never as code.
#
#   renew PASSWORD EMAIL...   each user afresh: removed if present, then made
#                             confirmed with PASSWORD
#   delete EMAIL...           each user that exists, with its sessions
#
# Run inside `fcon_web`, with only the database started:
#
#     mix run --no-start priv/dev/console_users.exs delete a@example.com

{:ok, _apps} = Application.ensure_all_started(:ecto_sql)
{:ok, _apps} = Application.ensure_all_started(:postgrex)
{:ok, _repo} = FlezhaConsole.Repo.start_link(pool_size: 1)

alias FlezhaConsole.Accounts

delete = fn email ->
  case Accounts.get_user_by_email(email) do
    nil -> :ok
    user -> FlezhaConsole.Repo.delete!(user)
  end
end

case System.argv() do
  ["renew", password | emails] ->
    for email <- emails do
      delete.(email)
      {:ok, _user} = Accounts.create_user(%{email: email, password: password})
    end

  ["delete" | emails] ->
    Enum.each(emails, delete)
end
