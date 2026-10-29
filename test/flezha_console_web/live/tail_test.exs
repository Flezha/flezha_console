defmodule FlezhaConsoleWeb.Live.TailTest do
  use ExUnit.Case, async: true

  alias FlezhaConsoleWeb.Live.Tail

  test "a record takes every record of its tail already waiting, newest first, up to the bound" do
    for n <- 2..5, do: send(self(), {:feed_event, :t, n})
    send(self(), {:feed_event, :other, :x})

    assert Tail.waiting([1], :t, 3) == [3, 2, 1]
    assert Tail.waiting([], :t, 10) == [5, 4]
    assert_received {:feed_event, :other, :x}
  end
end
