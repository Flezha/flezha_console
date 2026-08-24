# Claims the dev controller's authorization bootstrap and issues the token this
# UI presents.
#
# The controller enforces authorization by default and refuses every operator
# verb until the bootstrap is claimed. The stack must therefore claim it itself,
# because a dev environment that switched enforcement off would leave the whole
# identity path in this UI untested locally.
#
# Run as an Erlang node on the controller's network:
#
#     elixir --sname fui_bootstrap --cookie <cookie> priv/dev/bootstrap_authz.exs
#
# Environment:
#   FLEZHA_NODE        the controller node, e.g. flezha@flezha_controller
#   FLEZHA_TOKEN_FILE  where to write the issued token
#   FLEZHA_UI_PRINCIPAL  optional, defaults to "flezha-ui"
#
# `flz` cannot do this here: it shells out to the release launcher, which a
# controller running under `iex -S mix` does not have. The controller's own
# non-printing functions over `:erpc` are the entry point.

defmodule BootstrapAuthz do
  @connect_attempts 120
  @connect_interval_ms 2_000

  # Every store the claim and the UI's first calls reach into, in the order the
  # controller's authz supervisor starts them. The last one up is the gate.
  @required_stores [
    Flezha.AuthZ.AuthState,
    Flezha.AuthZ.RoleStore,
    Flezha.AuthZ.NamespaceStore,
    Flezha.AuthZ.TokenStore,
    Flezha.AuthZ.QuotaCounters
  ]

  def run do
    node = String.to_atom(env!("FLEZHA_NODE"))
    token_path = env!("FLEZHA_TOKEN_FILE")
    principal = System.get_env("FLEZHA_UI_PRINCIPAL") || "flezha-ui"

    connect!(node)
    await_ready!(node)

    case reusable_token(node, token_path) do
      {:ok, identity} ->
        say("reusing the token already at #{token_path} (#{describe(identity)})")

      :none ->
        token = obtain_token(node, principal)
        write!(token_path, token)
        say("wrote #{token_path}")
        report(node, token)
    end
  end

  # ---- Connecting ----

  defp connect!(node), do: connect!(node, @connect_attempts)

  defp connect!(node, 0) do
    die("could not reach #{node} after #{@connect_attempts} attempts")
  end

  defp connect!(node, attempts) do
    if Node.connect(node) == true do
      say("connected to #{node}")
    else
      Process.sleep(@connect_interval_ms)
      connect!(node, attempts - 1)
    end
  end

  # A node is reachable as soon as its VM is up, which under `iex -S mix` is
  # before the project has compiled — its modules are not loadable yet and
  # every call answers `:undef`. The posture is the readiness signal: it can
  # only be answered by a controller whose application has started.
  defp await_ready!(node), do: await_ready!(node, @connect_attempts)

  defp await_ready!(_node, 0) do
    die(
      "the controller never brought its authorization stores up: " <>
        Enum.map_join(@required_stores, ", ", &inspect/1)
    )
  end

  defp await_ready!(node, attempts) do
    posture = safe_call(node, Flezha.AuthZ, :enforcement_posture, [])

    cond do
      posture not in [:open, :bootstrap_pending, :enforced] ->
        retry(node, attempts, "waiting for the application to start")

      # A node that answers the posture is NOT yet a node that can claim: the
      # posture is a config read, while the claim is a `GenServer.call` into
      # stores the authz supervisor starts in sequence afterwards. Gating on
      # the posture alone races, and loses — the claim dies `:noproc`.
      missing = down_stores(node) ->
        retry(node, attempts, "waiting for #{Enum.map_join(missing, ", ", &inspect/1)}")

      true ->
        say("controller is up; authorization posture is #{posture}")
        posture
    end
  end

  # `[]` is falsy for `cond` purposes only if we say so, so this answers `nil`
  # when everything is up.
  defp down_stores(node) do
    case Enum.reject(@required_stores, &alive?(node, &1)) do
      [] -> nil
      missing -> missing
    end
  end

  defp alive?(node, name) do
    is_pid(safe_call(node, Process, :whereis, [name]))
  end

  defp retry(node, attempts, reason) do
    say(reason)
    Process.sleep(@connect_interval_ms)
    await_ready!(node, attempts - 1)
  end

  # ---- Reuse ----

  # A token that still verifies is the whole answer: nothing is re-claimed and
  # nothing is re-issued, so a restart is a no-op.
  defp reusable_token(node, path) do
    with {:ok, contents} <- File.read(path),
         token when token != "" <- String.trim(contents),
         {:ok, identity} <- call(node, Flezha.AuthZ.TokenStore, :verify, [token]) do
      {:ok, identity}
    else
      _ -> :none
    end
  end

  # ---- Claiming and issuing ----

  defp obtain_token(node, principal) do
    case claim(node) do
      {:ok, admin_token} ->
        issue(node, principal, token: admin_token, label: principal)

      :already_claimed ->
        # The controller was bootstrapped on an earlier run whose token is gone
        # — a wiped volume against a persistent controller. Enforcement is
        # already on, and this process holds the distribution cookie, which the
        # controller treats as node ownership, so the store is asked directly
        # rather than leaving the stack permanently unusable.
        say("bootstrap already claimed; minting a replacement token directly")
        issue_directly(node, principal)
    end
  end

  defp claim(node) do
    case bootstrap_token(node) do
      nil ->
        :already_claimed

      raw ->
        case call(node, Flezha.Service.CliManager, :authz_bootstrap, [raw, []]) do
          {:ok, %{principal: admin, minted_token: minted}} when is_binary(minted) ->
            say("claimed the bootstrap; admin@_system is #{admin}")
            {:ok, minted}

          {:error, :bootstrap_already_completed} ->
            :already_claimed

          other ->
            die("could not claim the bootstrap: #{inspect(other)}")
        end
    end
  end

  # Read on the controller, not here: the file lives in its container and is
  # mode 0600 for its own user.
  defp bootstrap_token(node) do
    path = call(node, Flezha.AuthZ.Config, :bootstrap_token_path, [])

    case call(node, File, :read, [path]) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> nil
    end
  end

  defp issue(node, principal, opts) do
    case call(node, Flezha.Service.CliManager, :authz_issue, [
           principal,
           "_system",
           :admin,
           :never,
           opts
         ]) do
      {:ok, raw, _entry} -> raw
      other -> die("could not issue a token for #{principal}: #{inspect(other)}")
    end
  end

  defp issue_directly(node, principal) do
    case call(node, Flezha.AuthZ.TokenStore, :issue, [
           principal,
           "_system",
           :admin,
           :never,
           [label: principal]
         ]) do
      {:ok, raw, _entry} -> raw
      other -> die("could not mint a token for #{principal}: #{inspect(other)}")
    end
  end

  defp report(node, token) do
    case call(node, Flezha.AuthZ.TokenStore, :verify, [token]) do
      {:ok, identity} -> say("the UI will call as #{describe(identity)}")
      other -> die("the issued token does not verify: #{inspect(other)}")
    end
  end

  # ---- Plumbing ----

  # `_system`-scoped and admin: cross-namespace reads are granted only to an
  # admin bound in `_system`, and the UI lists every namespace.
  defp describe(%{principal: principal, namespace: namespace, role: role}) do
    "#{principal} (#{role}@#{namespace})"
  end

  defp call(node, module, function, args) do
    :erpc.call(node, module, function, args, 30_000)
  catch
    kind, reason -> die("#{inspect(module)}.#{function} failed: #{kind} #{inspect(reason)}")
  end

  # As `call/4`, but a failure is an answer rather than the end — for polling.
  defp safe_call(node, module, function, args) do
    :erpc.call(node, module, function, args, 30_000)
  catch
    kind, reason -> {:not_ready, kind, reason}
  end

  defp write!(path, token) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, token)
    # Readable by the UI container, which runs as a different user.
    File.chmod!(path, 0o644)
  end

  defp env!(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> die("#{name} is not set")
      value -> value
    end
  end

  defp say(message), do: IO.puts("[bootstrap-authz] #{message}")

  defp die(message) do
    IO.puts(:stderr, "[bootstrap-authz] #{message}")
    System.halt(1)
  end
end

BootstrapAuthz.run()
