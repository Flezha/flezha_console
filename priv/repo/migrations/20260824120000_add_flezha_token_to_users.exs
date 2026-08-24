defmodule FlezhaUi.Repo.Migrations.AddFlezhaTokenToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :flezha_token, :binary
    end
  end
end
