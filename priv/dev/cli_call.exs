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
# Environment:
#   FLEZHA_NODE        the controller node, e.g. flezha@flezha_controller
#   FLEZHA_TOKEN_FILE  the token to call with

defmodule CliCall do
  @timeout_ms 60_000

  def run([name | [_ | _] = requests]) do
    node = String.to_atom(env!("FLEZHA_NODE"))
    token = env!("FLEZHA_TOKEN_FILE") |> File.read!() |> String.trim()

    Node.connect(node) || die("could not reach #{node}")

    # The door prints on this process's group leader, which the remote process
    # inherits, so its answer lands on this script's stdout.
    for args_json <- requests do
      :erpc.call(
        node,
        Flezha.Service.Cli,
        :call,
        [name, args_json, [token: token, output: "json"]],
        @timeout_ms
      )
    end
  catch
    kind, reason -> die("#{name} failed: #{kind} #{inspect(reason)}")
  end

  def run(_argv), do: die("usage: cli_call.exs <door name> <args as a JSON array>...")

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
