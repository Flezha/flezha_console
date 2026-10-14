# Makes and removes console users for the browser suite, on the dev stack's
# console node. Emails and passwords arrive as arguments, never as code.
#
#   renew PASSWORD EMAIL...   each user afresh: removed if present, then made
#                             confirmed with PASSWORD
#   delete EMAIL...           each user that exists, with its sessions
#
# Run inside `fui_web`, as a node of the dev stack:
#
#     elixir --sname <unique> --cookie <cookie> priv/dev/console_users.exs delete a@example.com

{:ok, host} = :inet.gethostname()
console = :"flezha_ui@#{host}"
true = Node.connect(console)

delete = fn email ->
  case :erpc.call(console, FlezhaUi.Accounts, :get_user_by_email, [email]) do
    nil -> :ok
    user -> :erpc.call(console, FlezhaUi.Repo, :delete!, [user])
  end
end

case System.argv() do
  ["renew", password | emails] ->
    for email <- emails do
      delete.(email)

      {:ok, _user} =
        :erpc.call(console, FlezhaUi.Accounts, :create_user, [
          %{email: email, password: password}
        ])
    end

  ["delete" | emails] ->
    Enum.each(emails, delete)
end
