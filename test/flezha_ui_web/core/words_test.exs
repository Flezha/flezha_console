defmodule FlezhaUiWeb.WordsTest do
  use ExUnit.Case, async: true

  alias FlezhaUiWeb.Words

  doctest FlezhaUiWeb.Words

  test "every state kind the operator-language spec names has words and a tone" do
    cases = [
      {:health, :suspended, "Suspended", :warning},
      {:authz_posture, :enforced, "Enforced — calls are checked against the caller's role",
       :positive},
      {:durability_posture, :local_only, "Durable state has one copy, on the node that wrote it",
       :neutral},
      {:readiness, :ready, "Ready", :positive},
      {:shutdown_phase, :drain, "Draining", :warning},
      {:signal_handler, :ok, "Installed", :positive},
      {:hub_recovery, :not_hosted, "No hub on this node", :neutral},
      {:schedule, true, "Active", :positive},
      {:namespace_state, {true, false}, "Declared, no hub running", :warning},
      {:quota, :breached, "At its limit", :negative},
      {:boolean, false, "No", :neutral}
    ]

    for {kind, value, text, tone} <- cases do
      assert Map.take(Words.say(kind, value), [:text, :tone]) == %{text: text, tone: tone},
             "#{kind} #{inspect(value)}"
    end
  end

  test "an unknown value is still said in words, never as an atom" do
    assert Words.say(:readiness, :warming_up) == %{text: "Warming up", tone: :neutral}
    assert Words.text(:hub_recovery, "recovering") == "Recovering"
    refute Words.humanize(:some_state) =~ ":"
  end

  test "every health verdict reads distinctly, unknown included, and nil reads as unknown" do
    texts = Enum.map(Words.health_verdicts(), &Words.text(:health, &1))

    assert length(Enum.uniq(texts)) == length(texts)
    assert Words.text(:health, nil) == "Unknown"
  end

  test "the worst of a set of tones" do
    assert Words.worst([:positive, :warning]) == :warning
    assert Words.worst([:warning, :negative]) == :negative
    assert Words.worst([]) == :neutral
  end
end
