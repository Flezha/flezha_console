defmodule FlezhaConsole.Release do
  @moduledoc """
  The tasks a release runs without Mix, through `bin/flezha_console eval`:

      bin/flezha_console eval "FlezhaConsole.Release.migrate()"
      bin/flezha_console eval "FlezhaConsole.Release.ensure_admin()"
  """

  alias FlezhaConsole.Accounts

  @app :flezha_console

  @doc "Runs every pending migration of every repository."
  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _migrated, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Makes the account `FLEZHA_CONSOLE_ADMIN_EMAIL` exist and log in with
  `FLEZHA_CONSOLE_ADMIN_PASSWORD`, so the credentials the operator keeps always work.
  """
  def ensure_admin do
    Application.load(@app)
    email = System.fetch_env!("FLEZHA_CONSOLE_ADMIN_EMAIL")
    password = System.fetch_env!("FLEZHA_CONSOLE_ADMIN_PASSWORD")

    {:ok, :ok, _apps} =
      Ecto.Migrator.with_repo(FlezhaConsole.Repo, fn _repo -> ensure_admin(email, password) end)

    :ok
  end

  @doc """
  Creates the account, or sets its password when it no longer matches; an
  account that already logs in with it is left alone, sessions included.
  """
  def ensure_admin(email, password) do
    result =
      case Accounts.get_user_by_email(email) do
        nil ->
          Accounts.create_user(%{email: email, password: password})

        user ->
          if Accounts.get_user_by_email_and_password(email, password),
            do: {:ok, user},
            else: Accounts.update_user_password(user, %{password: password})
      end

    case result do
      {:ok, _user} -> :ok
      {:error, changeset} -> raise "could not set up #{email}: #{inspect(changeset.errors)}"
    end
  end
end
