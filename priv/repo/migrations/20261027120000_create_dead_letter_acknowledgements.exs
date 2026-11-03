defmodule FlezhaConsole.Repo.Migrations.CreateDeadLetterAcknowledgements do
  use Ecto.Migration

  def change do
    create table(:dead_letter_acknowledgements) do
      add :ref, :string, null: false
      add :generation, :integer, null: false
      add :relay_class, :string, null: false
      add :acknowledged_by, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dead_letter_acknowledgements, [:ref, :generation])
    create index(:dead_letter_acknowledgements, [:relay_class])
  end
end
