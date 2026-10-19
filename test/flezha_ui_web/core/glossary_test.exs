defmodule FlezhaUiWeb.GlossaryTest do
  use ExUnit.Case, async: true

  alias FlezhaUiWeb.Glossary

  @required ~w(namespace relay run runner factory tasklet cell output) ++
              ["task journal", "input log"] ++
              ~w(plugin provider hook hub posture principal role quota) ++
              ["partition group", "coverage", "health"] ++
              ~w(suspended halted unbound failed recovering degraded) ++
              ["handled by", "dead letter"]

  test "every term the spec requires has a short definition" do
    for key <- @required do
      term = Glossary.term(key)
      assert term, "#{key} has no glossary entry"
      sentences = term.definition |> String.split(~r/(?<=\.)\s+/) |> length()
      assert sentences in 1..2, "#{key} is defined in #{sentences} sentences"
    end
  end

  test "every term in the README's vocabulary table has a glossary entry" do
    vocabulary =
      "README.md"
      |> File.read!()
      |> String.split("## Vocabulary")
      |> Enum.at(1)
      |> String.split("\n## ")
      |> hd()

    terms =
      for [_, term] <- Regex.scan(~r/^\| \*\*([^*]+)\*\* \|/m, vocabulary),
          do: String.downcase(term)

    assert length(terms) > 10

    for term <- terms do
      assert Glossary.term(term), "README term #{term} has no glossary entry"
    end
  end

  test "every screen kind has a purpose, and its terms are glossary entries" do
    for kind <- Glossary.screen_kinds() do
      assert %{purpose: purpose, terms: terms} = Glossary.screen(kind)
      assert String.length(purpose) > 40, "#{kind} has no real purpose"
      assert Enum.all?(terms, &is_map/1)
    end

    assert Glossary.screen(:nowhere) == nil
  end

  test "no glossary entry or relay-state word says parked or asleep" do
    copy =
      Enum.flat_map(Glossary.terms(), &[&1.name, &1.definition]) ++
        Enum.map(
          FlezhaUi.Service.NodeManager.health_verdicts(),
          &FlezhaUiWeb.Words.text(:health, &1)
        )

    for text <- copy, word <- ~w(parked asleep) do
      refute String.downcase(text) =~ word, "#{inspect(text)} says #{word}"
    end

    refute Glossary.term("parked")
  end

  test "the shortcuts list the keys the console binds" do
    keys = Glossary.shortcuts() |> Enum.map(&Enum.join(elem(&1, 0), " "))

    for key <- ["?", "g h", "g r", "g p", "g c", "Esc"], do: assert(key in keys)
  end
end
