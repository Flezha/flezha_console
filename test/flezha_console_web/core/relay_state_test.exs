defmodule FlezhaConsoleWeb.RelayStateTest do
  @moduledoc """
  What a relay's state means, who handles it and what happens next, fed the
  shapes the controller answers: `Relay.list/3` rows and the Overwatch's
  suspended flag.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias FlezhaConsoleWeb.RelayState

  defp row(id, overrides \\ %{}) do
    Map.merge(
      %{id: id, health: :healthy, runner: "r1", factory: "f", partition: nil, node: :flezha@a},
      overrides
    )
  end

  defp text(facts, key) do
    case facts[key] do
      %{text: text} -> text
      other -> other
    end
  end

  # Who handles a state and the next step follow the state and whether a
  # runner serves the factory, and never claim a wake nobody can make.
  @rows [
    {:suspended, 2, "Nobody", "Wakes on the next message or its timer"},
    {:suspended, 0, "You", "Start a runner that serves orders"},
    {:suspended, nil, nil, nil},
    {:unbound, 1, "Flezha", "Bound to a runner by Flezha"},
    {:unbound, 0, "You", "Start a runner that serves orders"},
    {:unbound, nil, "Flezha", "Bound to a runner by Flezha"},
    {:failed, 3, "Flezha", "Rebound to another runner by Flezha"},
    {:failed, 0, "You", "Start a runner that serves orders"},
    {:recovering, 1, "Flezha", "Rebound by Flezha within its grace"},
    {:recovering, 0, "You", "Start a runner that serves orders"},
    {:degraded, nil, "Flezha", "Repaired in place by Flezha"},
    {:halted, 0, "You", "Fix the cause; Flezha retries its bind with a growing delay"},
    {:halted, 2, "You", "Fix the cause; Flezha retries its bind with a growing delay"},
    {:unknown, nil, "Flezha", "Read again on the next tick"},
    {:unplaced, 1, "Flezha", "Placed by Flezha"},
    {:coverage, 1, "You", "Fix the group's key ranges"},
    {:healthy, 1, "Nobody", nil}
  ]

  test "who handles a relay and what happens next follow its state and the runners serving it" do
    for {state, serving, handled, next} <- @rows do
      rows = RelayState.condition_facts(state, serving: serving, factory: "orders")
      assert text(rows, :handled) == handled, "#{state} / #{inspect(serving)}"
      assert text(rows, :next) == next, "#{state} / #{inspect(serving)}"
    end
  end

  test "every state has a cause, and every state but healthy an impact" do
    for {state, _serving, _handled, _next} <- @rows do
      rows = RelayState.condition_facts(state)
      assert is_binary(rows[:cause]), "#{state}"
      assert is_binary(rows[:impact]) == (state != :healthy), "#{state}"
    end
  end

  test "an unknown relay is one its controller did not answer for, or has not judged yet" do
    assert RelayState.condition_facts(:unknown)[:cause] ==
             "Its controller did not answer, or has not checked it yet"
  end

  test "a finding that no runner can take the relay outranks the count of serving runners" do
    for code <- ~w(diagnose.no_runner diagnose.runner_mismatch) do
      diagnosis = %{verdict: :problem, findings: [%{code: code}]}
      rows = RelayState.condition_facts(:suspended, serving: 2, diagnosis: diagnosis)

      assert RelayState.handled_by(:suspended, 2, diagnosis) == :you
      assert text(rows, :handled) == "You"
      assert text(rows, :next) == "Start a runner that can take it"
    end

    other = %{verdict: :warning, findings: [%{code: "diagnose.dead_letters"}]}
    assert text(RelayState.condition_facts(:halted, diagnosis: other), :next) =~ "Fix the cause"
  end

  test "the runner row says who is bound and, once read, how many can run it" do
    runner = &RelayState.condition_facts(:suspended, &1)[:runner]

    assert runner.(runner: nil, serving: 1, factory: "echo_steps") ==
             "None bound · 1 can run it (echo_steps)"

    assert runner.(runner: "r9", serving: nil) == "r9 bound"
    assert runner.(serving: 0, factory: "echo_steps") == "0 can run it (echo_steps)"
    assert runner.([]) == nil
  end

  test "a relay's state is suspended when the registry reads it healthy but it is suspended" do
    assert RelayState.of(row("r"), true) == :suspended
    assert RelayState.of(row("r", %{health: :halted}), true) == :halted
    assert RelayState.of(row("r"), false) == :healthy
    assert RelayState.of(nil, true) == :suspended
    assert RelayState.of(nil, false) == :unknown
  end

  test "a call is refused only while no runner serves the factory" do
    assert RelayState.unservable(0, "orders") =~ "until a runner serves factory orders"
    assert RelayState.unservable(nil, "orders") == nil
    assert RelayState.unservable(2, "orders") == nil
  end

  test "a send to a relay no runner serves is noted by what the controller does with it" do
    assert RelayState.no_runner_note(:suspended, 0, "orders") ==
             "No runner serves orders yet; the message is kept until one connects. " <>
               "Call is off. Nobody can answer a call until a runner serves factory orders."

    assert RelayState.no_runner_note(:unbound, 0, "orders") =~
             "only if this relay journals its input"

    assert RelayState.no_runner_note(:suspended, 1, "orders") == nil
    assert RelayState.no_runner_note(:suspended, nil, "orders") == nil
  end

  test "the summary renders its rows in order, with no old labels" do
    html =
      render_component(&RelayState.summary/1,
        state: :suspended,
        factory: "echo_steps",
        runner: nil,
        serving: 1
      )

    labels =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("dt")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert labels == ["State", "Cause", "Impact", "Runner", "Handled by", "Next step"]
    refute html =~ "Who can run it"
    refute html =~ "What happens next"
  end
end
