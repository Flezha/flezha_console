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
#     elixir --sname fcon_bootstrap --cookie <cookie> priv/dev/bootstrap_authz.exs
#
# Environment:
#   FLEZHA_NODE        the controller node, e.g. flezha@flezha_controller
#   FLEZHA_TOKEN_FILE  where to write the issued token
#   FLEZHA_CONSOLE_PRINCIPAL  optional, defaults to "flezha-console"
#   FLEZHA_RUNNER_TOKEN_FILE  optional: where to write a runner credential, so
#                      the dev runner can prove its namespace to a controller
#                      that enforces authorization
#   FLEZHA_RUNNER_NAMESPACE  the namespace that credential is for (default),
#                      created when missing
#
# It also enables the HTTP API the console reaches the controllers through.
#
# `flz` cannot do this here: it shells out to the release launcher, which a
# controller running under `iex -S mix` does not have. The published
# `Flezha.Service.Namespace` functions over `:erpc` are the entry point.

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
    principal = System.get_env("FLEZHA_CONSOLE_PRINCIPAL") || "flezha-console"

    connect!(node)
    await_ready!(node)

    ui_token =
      case reusable_token(node, token_path) do
        {:ok, identity} ->
          say("reusing the token already at #{token_path} (#{describe(identity)})")
          token_path |> File.read!() |> String.trim()

        :none ->
          token = obtain_token(node, principal)
          write!(token_path, token)
          say("wrote #{token_path}")
          report(node, token)
          token
      end

    ensure_runner_token(node, ui_token)
    ensure_http_api(node, ui_token)
  end

  # The console reaches the controllers over the HTTP API with mutual TLS. One
  # plugin serves every controller; each links its own certificate to the paths
  # below before it boots (docker-compose.dev.yml).
  @http_api_opts %{
    "bind" => "0.0.0.0",
    "port" => 8765,
    "tls_certfile" => "/tmp/channel_server.pem",
    "tls_keyfile" => "/tmp/channel_server.key",
    "tls_client_cacertfile" => "/channel_tls/ca.pem"
  }

  defp ensure_http_api(node, admin_token) do
    context = context_of(node, admin_token)
    fields = [provider: "http_api", namespace: "_system", opts: @http_api_opts]

    case call(node, Flezha.Service.PluginManager, :enable, ["api", fields, context]) do
      {:ok, %{outcome: :enabled}} ->
        say("enabled http_api on every controller")

      {:ok, %{outcome: :already_enabled}} ->
        update = [namespace: "_system", opts: @http_api_opts]

        case call(node, Flezha.Service.PluginManager, :update, ["api", update, context]) do
          {:ok, _applied} -> say("http_api is enabled")
          other -> die("could not update http_api: #{inspect(other)}")
        end

      other ->
        die("could not enable http_api: #{inspect(other)}")
    end
  end

  # A runner proves the namespace it serves with a `runner` credential when
  # enforcement is on. Issued by the UI's own `_system` admin token.
  defp ensure_runner_token(node, ui_token) do
    case System.get_env("FLEZHA_RUNNER_TOKEN_FILE") do
      path when path in [nil, ""] ->
        :ok

      path ->
        namespace = System.get_env("FLEZHA_RUNNER_NAMESPACE") || "default"
        ensure_namespace(node, ui_token, namespace)

        if match?({:ok, _}, reusable_token(node, path)) do
          say("reusing the runner credential already at #{path}")
        else
          write!(path, issue_as(node, ui_token, "runner@#{namespace}", namespace, "runner"))
          say("wrote #{path} for runner@#{namespace}")
        end
    end
  end

  # Under enforcement a runner may join only a namespace that was created.
  defp ensure_namespace(node, issuer_token, namespace) do
    case call(node, Flezha.AuthZ.NamespaceStore, :get, [namespace]) do
      {:ok, _entry} ->
        :ok

      :error ->
        context = context_of(node, issuer_token)

        case call(node, Flezha.Service.Namespace, :create, [namespace, [], context]) do
          {:ok, _entry} -> say("created namespace #{namespace}")
          other -> die("could not create namespace #{namespace}: #{inspect(other)}")
        end
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
        issue(node, principal, admin_token)

      :already_claimed ->
        # The controller was bootstrapped on an earlier run whose token is gone
        # — a wiped volume against a persistent controller. No published
        # operation mints a token without holding one, but this process holds
        # the distribution cookie, which the controller treats as node
        # ownership, so the token store is asked directly rather than leaving
        # the stack permanently unusable.
        say("bootstrap already claimed; minting a replacement token directly")
        issue_directly(node, principal)
    end
  end

  defp claim(node) do
    case bootstrap_token(node) do
      nil ->
        :already_claimed

      raw ->
        # Claiming is what a context is built from, so it is called with an
        # unbound one; the token it mints is the claimant's.
        case call(node, Flezha.Service.Namespace, :bootstrap, [raw, %{source: :cli}]) do
          {:ok, %{principal: admin, minted_token: minted}} when is_binary(minted) ->
            say("claimed the bootstrap; admin@_system is #{admin}")
            {:ok, minted}

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

  # Issued as the admin the claim just bound.
  defp issue(node, principal, admin_token),
    do: issue_as(node, admin_token, principal, "_system", "admin")

  # A token issued with the identity `issuer_token` verifies as, so the
  # controller attributes and authorizes it as that identity.
  defp issue_as(node, issuer_token, principal, namespace, role) do
    case call(node, Flezha.Service.Namespace, :issue_token, [
           principal,
           namespace,
           role,
           [ttl: "never", label: principal],
           context_of(node, issuer_token)
         ]) do
      {:ok, %{token: raw}} -> raw
      other -> die("could not issue a #{role} token for #{principal}: #{inspect(other)}")
    end
  end

  # The caller context a verb is authorized and attributed as: the identity
  # `token` verifies as.
  defp context_of(node, token) do
    {:ok, identity} = call(node, Flezha.AuthZ.TokenStore, :verify, [token])

    %{
      source: :cli,
      principal: identity.principal,
      namespace: identity.namespace,
      role: identity.role
    }
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
