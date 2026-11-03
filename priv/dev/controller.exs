# Drives a dev controller over Erlang distribution, for priv/dev/stack.sh.
# Run inside `fcon_tools`, as a hidden node of the dev stack:
#
#     elixir --sname <unique> --hidden --cookie <cookie> priv/dev/controller.exs <command> <node>
#
#   stop <node>             drains and stops it, as `flz controller stop` does,
#                           and returns once it is gone
#   await <node> [seconds]  waits until it is back and ready (default 600 s)
#   status <node>           prints whether it answers and how ready it is

defmodule DevController do
  @poll_ms 2_000

  def run(["stop", name]) do
    node = String.to_atom(name)
    connect!(node)

    {:ok, _pid} =
      :erpc.call(node, Task, :start, [Flezha.Shutdown.Coordinator, :shutdown_and_stop, [:cli]])

    # The drain is bounded by the controller's graceful-shutdown timeout, 5 s
    # in the dev stack unless FLEZHA_GRACEFUL_SHUTDOWN_TIMEOUT_MS raises it.
    wait_until(90, fn -> Node.ping(node) == :pang end) ||
      die("#{node} is still up 90 s after it was asked to stop")

    IO.puts("#{node} stopped")
  end

  def run(["await", name | seconds]) do
    node = String.to_atom(name)
    limit = seconds |> List.first("600") |> String.to_integer()

    wait_until(limit, fn -> verdict(node) == :ready end) ||
      die("#{node} is not ready after #{limit} s: #{inspect(verdict(node))}")

    IO.puts("#{node} ready")
  end

  def run(["status", name]) do
    node = String.to_atom(name)
    IO.puts("#{node}: #{verdict(node)}")
  end

  def run(_argv), do: die("usage: controller.exs stop|await|status <node> [seconds]")

  # :ready, :booting or :recovering as the controller judges itself, or :down.
  defp verdict(node) do
    with :pong <- Node.ping(node),
         {verdict, _rows} <- :erpc.call(node, Flezha.Boot.Readiness, :verdict, [], 5_000) do
      verdict
    else
      _ -> :down
    end
  catch
    _kind, _reason -> :down
  end

  defp wait_until(seconds, check),
    do: poll(System.monotonic_time(:millisecond) + seconds * 1_000, check)

  defp poll(deadline, check) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        poll(deadline, check)
    end
  end

  defp connect!(node), do: Node.connect(node) == true || die("cannot reach #{node}")

  defp die(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end

DevController.run(System.argv())
