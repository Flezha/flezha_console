# Sends one request to the dev controller exactly as `flz` sends it, so the
# controller treats it as a CLI call (caller source `cli`).
#
# `flz` cannot do this here: it shells out to the release launcher, which a
# controller running under `iex -S mix` does not have. What it would send is
# one door request, `Flezha.Service.Cli.call(name, args_json, opts)`, evaluated
# on the controller node; this script sends that request over `:erpc`.
#
# Run as an Erlang node on the controller's network, e.g. inside `fui_web`:
#
#     elixir --sname <unique> --cookie <cookie> priv/dev/cli_call.exs \
#       Relay.call_channel '["default","orders","place",{"pair":"BTC-EUR","amount":1},{}]'
#
# Several argument arrays send that many requests, in order, from one node,
# so a caller that needs many records pays for one boot:
#
#     elixir ... priv/dev/cli_call.exs Relay.send '["default","r1","input","a"]' \
#       '["default","r1","input","b"]'
#
# Prints each door's JSON answer and exits 0, or prints the failure and exits 1.
#
# With `--serve` it stays up and answers one request per stdin line instead,
# so a caller that makes many calls boots one node rather than one per call.
#
# Environment:
#   FLEZHA_NODE        the controller node, e.g. flezha@flezha_controller
#   FLEZHA_TOKEN_FILE  the token to call with

defmodule CliCall do
  @timeout_ms 60_000

  def run(["--serve"]) do
    {node, token} = connect()
    serve(node, token)
  end

  def run([name | [_ | _] = requests]) do
    {node, token} = connect()
    for args_json <- requests, do: door(node, name, args_json, token)
  catch
    kind, reason -> die("#{name} failed: #{kind} #{inspect(reason)}")
  end

  def run(_argv),
    do: die("usage: cli_call.exs <door name> <args as a JSON array>... | --serve")

  defp connect do
    node = String.to_atom(env!("FLEZHA_NODE"))
    token = env!("FLEZHA_TOKEN_FILE") |> File.read!() |> String.trim()

    Node.connect(node) || die("could not reach #{node}")
    {node, token}
  end

  # The door prints on this process's group leader, which the remote process
  # inherits, so its answer lands on this script's stdout.
  defp door(node, name, args_json, token) do
    :erpc.call(
      node,
      Flezha.Service.Cli,
      :call,
      [name, args_json, [token: token, output: "json"]],
      @timeout_ms
    )
  end

  # Reads one request per line, `{"door": name, "args": [args, ...]}`, until
  # stdin closes, and answers each with one line: `{"ok": true, "out": ...}`
  # or `{"ok": false, "out": ..., "error": ...}`. A caller pays for one node
  # boot however many calls it makes.
  defp serve(node, token) do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        %{"door" => name, "args" => requests} = JSON.decode!(line)
        IO.puts(JSON.encode!(answer(node, name, requests, token)))
        serve(node, token)

      _eof ->
        :ok
    end
  end

  # A door prints its answer on the group leader and its failure on the
  # calling node's standard_error; this node is the caller and serves no one
  # else, so both are captured for the length of one request.
  defp answer(node, name, requests, token) do
    {:ok, out} = StringIO.open("")
    {:ok, err} = StringIO.open("")
    leader = Process.group_leader()
    stderr = Process.whereis(:standard_error)
    use_stderr(err)
    Process.group_leader(self(), out)

    result =
      try do
        for args <- requests, do: door(node, name, JSON.encode!(args), token)
        :ok
      catch
        kind, reason -> {:error, "#{kind} #{inspect(reason)}"}
      after
        Process.group_leader(self(), leader)
        use_stderr(stderr)
      end

    {_, printed} = StringIO.contents(out)
    {_, errors} = StringIO.contents(err)

    case result do
      :ok -> %{ok: true, out: printed}
      {:error, reason} -> %{ok: false, out: printed, error: errors <> reason}
    end
  end

  defp use_stderr(device) do
    Process.unregister(:standard_error)
    Process.register(device, :standard_error)
  end

  defp env!(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> die("#{name} is not set")
      value -> value
    end
  end

  defp die(message) do
    IO.puts(:stderr, "[cli-call] #{message}")
    System.halt(1)
  end
end

CliCall.run(System.argv())
