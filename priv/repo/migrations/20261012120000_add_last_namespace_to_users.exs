defmodule FlezhaConsole.Repo.Migrations.AddLastNamespaceToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_namespace, :string
    end
  end
end
