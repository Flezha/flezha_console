defmodule Mix.Tasks.FlezhaUi.CreateUser do
  @shortdoc "Creates a confirmed console account"

  @moduledoc """
  Creates a console account, confirmed and ready to log in with its password.
  The console has no registration page, so this is how accounts are made.

      mix flezha_ui.create_user EMAIL
      mix flezha_ui.create_user EMAIL --password PASSWORD

  Without `--password` it asks for one without echoing it. The password must
  be 12 to 72 characters. In the dev stack, run it inside the web container:

      docker exec -it fui_web mix flezha_ui.create_user ops@example.com

  Only the repository is started, so it runs beside a console that is already
  serving.
  """

  use Mix.Task

  alias FlezhaUi.Accounts

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: [password: :string]) do
      {opts, [email], []} ->
        password = opts[:password] || prompt_password()

        {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

        Ecto.Migrator.with_repo(FlezhaUi.Repo, fn _repo ->
          create(email, password)
        end)

      _other ->
        Mix.raise("usage: mix flezha_ui.create_user EMAIL [--password PASSWORD]")
    end
  end

  defp create(email, password) do
    case Accounts.create_user(%{email: email, password: password}) do
      {:ok, user} ->
        Mix.shell().info("Created #{user.email}. It can log in now.")

      {:error, changeset} ->
        Mix.raise("Could not create #{email}: #{errors(changeset)}")
    end
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&FlezhaUiWeb.CoreComponents.translate_error/1)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  # Erases the line as it is typed, the way Hex prompts for a password.
  defp prompt_password do
    pid = spawn_link(fn -> erase_input("Password: ") end)
    password = IO.gets("Password: ")
    send(pid, {:done, self()})

    receive do
      :done -> :ok
    end

    String.trim_trailing(password, "\n")
  end

  defp erase_input(prompt) do
    receive do
      {:done, parent} -> send(parent, :done)
    after
      1 ->
        IO.write("\e[2K\r#{prompt}")
        erase_input(prompt)
    end
  end
end
