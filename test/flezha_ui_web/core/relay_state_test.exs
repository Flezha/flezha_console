defmodule FlezhaUiWeb.RelayStateTest do
  @moduledoc """
  What a relay's state means and what happens to it next, fed the shapes the
  controller answers: `relay_rows/2` rows and the Overwatch's suspended flag.
  """

  use ExUnit.Case, async: true

  alias FlezhaUiWeb.RelayState

  defp row(id, overrides \\ %{}) do
    Map.merge(
      %{id: id, health: :healthy, runner: "r1", factory: "f", partition: nil, node: :flezha@a},
      overrides
    )
  end

  # What happens next follows the state and whether a runner serves the
  # factory, and never claims a wake nobody can make.
  @next [
    {:suspended, 2, "The next message wakes it on a runner."},
    {:suspended, 0, "Messages are kept, but it cannot run until a runner for orders connects."},
    {:suspended, nil, nil},
    {:parked, 0,
     "It stays stopped until someone fixes it; the Convergence Loop does not touch it."},
    {:unbound, 1, "The Convergence Loop is binding it to a runner."},
    {:unbound, 0, "It waits until a runner for orders connects."},
    {:failed, nil, "The Convergence Loop is binding it to a runner."},
    {:recovering, 1, "The Convergence Loop is rebinding it within its grace."},
    {:degraded, nil, "The Convergence Loop is repairing it in place."},
    {:healthy, 1, nil}
  ]

  test "what happens next depends on the state and the runners serving its factory" do
    for {state, serving, next} <- @next do
      assert RelayState.next_step(state, serving, "orders") == next,
             "#{state} / #{inspect(serving)}"
    end
  end

  test "a relay's state is suspended when the registry reads it healthy but it is suspended" do
    assert RelayState.of(row("r"), true) == :suspended
    assert RelayState.of(row("r", %{health: :parked}), true) == :parked
    assert RelayState.of(row("r"), false) == :healthy
    assert RelayState.of(nil, true) == :suspended
    assert RelayState.of(nil, false) == :unknown
  end

  test "nothing is refused while the runners are unread, or while one serves" do
    assert RelayState.unservable(0, "orders") =~ "No runner serves factory orders"
    assert RelayState.unservable(nil, "orders") == nil
    assert RelayState.unservable(2, "orders") == nil
  end
end
