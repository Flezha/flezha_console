# Records the shape of the dev controller's answer to each published read the
# console makes (`FlezhaUi.ControllerShapes.reads/0`) into
# `test/support/fixtures/controller_shapes.json`, which the fake controller's
# answers are checked against. With `--check` it records into memory instead
# and fails, naming each read whose answer no longer has the committed shape.
#
# Run inside `fui_web`, as a node of the dev stack:
#
#     elixir --sname <unique> --cookie <cookie> priv/dev/record_shapes.exs [--check]
#
# Environment:
#   FLEZHA_NODE        the controller node, e.g. flezha@flezha_controller
#   FLEZHA_TOKEN_FILE  the token whose caller context the reads carry

Code.require_file("../../test/support/controller_shapes.ex", __DIR__)

defmodule RecordShapes do
  alias FlezhaUi.ControllerShapes, as: Shapes

  @committed Path.expand("../../test/support/fixtures/controller_shapes.json", __DIR__)
  @timeout_ms 30_000

  def run(argv) do
    controller = String.to_atom(env!("FLEZHA_NODE"))
    token = env!("FLEZHA_TOKEN_FILE") |> File.read!() |> String.trim()
    {:ok, host} = :inet.gethostname()
    console = :"flezha_ui@#{host}"

    Node.connect(controller) || die("could not reach #{controller}")
    Node.connect(console) || die("could not reach #{console}")

    context = :erpc.call(console, FlezhaUi.Service.NodeManager, :caller_context, [token])

    if map_size(context) < 2,
      do: die("the console's token binds no identity: #{inspect(context)}")

    recorded =
      Map.new(Shapes.reads(), fn {label, module, function, args} ->
        answer = :erpc.call(controller, module, function, args ++ [context], @timeout_ms)
        {label, Shapes.of(answer)}
      end)

    case argv do
      [] ->
        File.write!(@committed, Shapes.encode(recorded))
        IO.puts("recorded #{map_size(recorded)} reads into #{@committed}")

      ["--check"] ->
        check(recorded)

      _ ->
        die("usage: record_shapes.exs [--check]")
    end
  end

  defp check(recorded) do
    committed = @committed |> File.read!() |> JSON.decode!()

    drift =
      for {label, shape} <- Enum.sort(recorded),
          line <- drift(Map.get(committed, label), shape),
          do: "#{label}#{line}"

    if drift == [] do
      IO.puts("every read has its committed shape")
    else
      die(
        "the controller's answers moved from the committed shapes; re-record with " <>
          "priv/dev/record_shapes.exs and update FakeController to match:\n" <>
          Enum.join(drift, "\n")
      )
    end
  end

  defp drift(nil, _shape), do: [": not in the committed file"]

  # A key the controller added or dropped both show here; which alternatives a
  # union holds depends on what the stack happens to run, so only fit counts.
  defp drift(committed, shape), do: Shapes.diff(committed, shape)

  defp env!(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> die("#{name} is not set")
      value -> value
    end
  end

  defp die(message) do
    IO.puts(:stderr, "[record-shapes] #{message}")
    System.halt(1)
  end
end

RecordShapes.run(System.argv())
