defmodule FlezhaConsoleWeb.LogLinesTest do
  use ExUnit.Case, async: true

  alias FlezhaConsole.Format
  alias FlezhaConsoleWeb.LogLines

  defp ended(relay, overrides),
    do: FakeController.history_record(relay, Map.merge(%{"event" => "ended"}, overrides))

  defp said(record), do: LogLines.sentence("relay_history", record)
  defp text(record), do: record |> said() |> LogLines.text()

  # Nothing of the record's Elixir shape reaches what the operator reads.
  defp assert_words(text) do
    refute text =~ ~r/(^|\s):[a-z_]+/, text
    refute text =~ "Elixir.", text
    refute text =~ ~r/\bnil\b/, text
    refute text =~ "%{", text
    text
  end

  describe "an ended run's outcome" do
    for {outcome, words, tone} <- [
          {"completed", "completed", :positive},
          {"undone", "undone", :warning},
          {"failed", "failed", :negative},
          {"cancelled", "cancelled", :neutral},
          {"timed_out", "ran out of time", :warning},
          {"stopped", "stopped", :neutral},
          {"rescaled_away", "removed by a rescale", :neutral}
        ] do
      test "#{outcome} reads as #{words} in the #{tone} tone" do
        record = ended("r1", %{"outcome" => unquote(outcome), "duration_ms" => 2_000})

        assert text(record) |> assert_words() =~ "r1 finished: #{unquote(words)} after 2 s"
        assert said(record).tone == unquote(tone)
        assert LogLines.tone(record) == unquote(tone)
      end
    end

    test "a spawned run that was undone reads as the spec says, its parent linked" do
      record =
        ended("fan_trade-7f3a", %{
          "outcome" => "undone",
          "duration_ms" => 41_000,
          "origin" => %{"kind" => "spawn", "parent_relay" => "ma_fan"}
        })

      line = said(record)

      assert LogLines.text(line) ==
               "fan_trade-7f3a finished: undone after 41 s, spawned by ma_fan"

      assert line.tone == :warning
      assert {:relay, "default", "ma_fan"} in line.parts
      assert {:relay, "default", "fan_trade-7f3a"} in line.parts
    end

    test "an operator stop says it was stopped and who started it" do
      record =
        ended("r1", %{
          "outcome" => "stopped",
          "duration_ms" => 5_000,
          "origin" => %{"kind" => "operator", "principal" => "ops@acme"}
        })

      assert text(record) == "r1 finished: stopped after 5 s, started by ops@acme"
      assert said(record).tone == :neutral
    end

    test "a record with no duration says its outcome with no placeholder" do
      record = ended("r1", %{"outcome" => "failed"})

      text = record |> text() |> assert_words()

      assert text =~ "r1 finished: failed, started by"
      refute text =~ "after"
      refute text =~ "—"
    end

    test "a halted run says it halted before it ended" do
      record = ended("r1", %{"outcome" => "failed", "halted" => true, "duration_ms" => 1_500})

      assert text(record) =~ "r1 finished: failed after 1 s, having halted first"
    end

    test "an error is added after the sentence" do
      record = ended("r1", %{"outcome" => "failed", "error" => "boom"})

      assert List.last(said(record).parts) == {:error, "boom"}
      assert text(record) =~ ~r/\. boom$/
    end

    test "an ended record with no outcome says only that it finished" do
      assert ended("r1", %{"origin" => nil}) |> text() == "r1 finished"
    end
  end

  describe "a start" do
    test "names the factory it started from, linked" do
      record = FakeController.history_record("r1")
      line = said(record)

      assert LogLines.text(line) ==
               "r1 started from store_input, started by ops@acme through the UI"

      assert {:factory, "default", "store_input"} in line.parts
      assert line.tone == :neutral
    end

    test "a failed start names the factory and the error, in the negative tone" do
      record =
        FakeController.history_record("fan_trade-7f3a", %{
          "event" => "start_failed",
          "factory" => "fan_trade",
          "error" => "no runner serves it"
        })

      assert text(record) == "fan_trade-7f3a could not start from fan_trade: no runner serves it"
      assert said(record).tone == :negative
    end

    test "an event the console does not know is still said in words" do
      record = FakeController.history_record("r1", %{"event" => "moved_away"})

      assert record |> text() |> assert_words() == "r1 moved away"
    end
  end

  describe "an origin" do
    for {origin, words} <- [
          {%{"kind" => "operator", "principal" => "ops@acme", "source" => "cli"},
           "started by ops@acme through the CLI"},
          {%{"kind" => "operator", "source" => "ui"}, "started by an operator through the UI"},
          {%{"kind" => "operator"}, "started by an operator"},
          {%{"kind" => "schedule", "schedule" => "nightly"}, "started by schedule nightly"},
          {%{"kind" => "spawn", "parent_relay" => "ma_fan"}, "spawned by ma_fan"},
          {%{"kind" => "spawn"}, "spawned by another relay"},
          {%{"kind" => "call", "parent_relay" => "ma_fan"}, "started by a call from ma_fan"},
          {%{"kind" => "group"}, "started with its partition group"},
          {%{"kind" => "rescale"}, "started by a rescale"},
          {%{"kind" => "reconcile"}, "started again by the controller"},
          {%{"kind" => "teleport"}, "teleport"}
        ] do
      test "#{origin["kind"]} reads #{words}" do
        record = FakeController.history_record("r1", %{"origin" => unquote(Macro.escape(origin))})

        assert record |> text() |> assert_words() ==
                 "r1 started from store_input, #{unquote(words)}"
      end
    end

    test "a record naming no origin leaves it out" do
      record = FakeController.history_record("r1", %{"origin" => %{}})

      assert text(record) == "r1 started from store_input"
      assert LogLines.origin_line(record) == nil
    end

    test "stands as a line of its own, capitalised" do
      record =
        FakeController.history_record("r1", %{
          "origin" => %{"kind" => "spawn", "parent_relay" => "ma_fan"}
        })

      line = LogLines.origin_line(record)

      assert LogLines.text(line) == "Spawned by ma_fan"
      assert {:relay, "default", "ma_fan"} in line.parts
    end
  end

  test "a kind with no sentence answers nil, so it is listed by its columns" do
    assert LogLines.sentence("audit", %{"name" => "x"}) == nil
    assert LogLines.sentence("deploys", %{}) == nil
  end

  describe "a declared column's cell" do
    test "says a missing or empty value as a dash" do
      assert LogLines.cell(%{}, "name") == "—"
      assert LogLines.cell(%{"name" => ""}, "name") == "—"
      assert LogLines.cell(%{"name" => nil}, "name") == "—"
    end

    test "says a map by its values and a boolean in words" do
      caller = %{"principal" => "flezha-console", "request_id" => nil, "source" => "ui"}

      assert LogLines.cell(%{"caller" => caller}, "caller") == "flezha-console · ui"
      assert LogLines.cell(%{"halted" => true}, "halted") == "Yes"
      assert LogLines.cell(%{"halted" => false}, "halted") == "No"
      assert LogLines.cell(%{"duration_ms" => 41_000}, "duration_ms") == "41000"
    end
  end

  test "an enum filter's choices are said in words" do
    assert LogLines.choice("outcome", "timed_out") == "Ran out of time"
    assert LogLines.choice("outcome", "undone") == "Undone"
    assert LogLines.choice("event", "start_failed") == "Start failed"
  end

  test "a record's time is its controller's stamp, in milliseconds" do
    assert LogLines.time(%{"ts_us" => 1_793_274_705_327_942}) == 1_793_274_705_327
    assert LogLines.time(%{}) == nil
  end

  test "an undone outcome says what it means" do
    assert LogLines.outcome_note("undone") =~ "compensated"
    assert LogLines.outcome_note("completed") == nil
  end

  test "how long something took reads in seconds under a minute" do
    assert Format.took(41_000) == "41 s"
    assert Format.took(1_000) == "1 s"
    assert Format.took(400) == "400ms"
    assert Format.took(125_000) == "2m 5s"
  end
end
