defmodule FlezhaConsole.DeadLetters.Acknowledgement do
  @moduledoc "One dead letter, at one generation, marked seen by an operator."

  use Ecto.Schema

  schema "dead_letter_acknowledgements" do
    field :ref, :string
    field :generation, :integer
    field :relay_class, :string
    field :acknowledged_by, :string

    timestamps(type: :utc_datetime)
  end
end
