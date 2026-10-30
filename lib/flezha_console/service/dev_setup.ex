defmodule FlezhaConsole.Service.DevSetup do
  @moduledoc """
  Dev-only GenServer that seeds testnet relays and plugins through the
  published API, with the service token, when the controller node becomes
  available. Retries every 5s for up to 5 minutes. Resets and re-attempts on
  nodedown.

  Idempotent: a relay already running is left alone, and a plugin already
  enabled answers `already_enabled` and only takes the seed's options, so a UI
  restart against a seeded controller changes nothing unless a seed changed. A
  relay seed marked `optional` is skipped, with the plugins bound to it and one
  log line, when no runner announces its factory.
  """

  use GenServer
  require Logger

  alias FlezhaConsole.Service.NodeManager

  @retry_interval 5_000
  @max_retries 60

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:flezha_console, :dev_setup)
    {:ok, %{config: config, retries: 0, ready: false}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    {:noreply, attempt_setup(state)}
  end

  @impl true
  def handle_info(:retry, state) do
    {:noreply, attempt_setup(state)}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("[DevSetup] Controller node #{node} went down, will re-attempt on reconnect")
    {:noreply, %{state | retries: 0, ready: false}, {:continue, :setup}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp attempt_setup(%{retries: retries} = state) when retries >= @max_retries do
    Logger.error("[DevSetup] Gave up after #{retries} retries")
    state
  end

  defp attempt_setup(%{ready: true} = state), do: state

  defp attempt_setup(%{config: config, retries: retries} = state) do
    ns = config[:namespace]
    relays = config[:relays] || []
    plugins = config[:plugins] || []
    token = FlezhaConsole.Accounts.service_flezha_token()

    try do
      with {:node, node} when node != nil <- {:node, NodeManager.connected_node()},
           :ok <- ensure_namespace(ns, config[:quotas] || %{}, token),
           {:ok, relays, skipped} <- drop_unannounced(ns, relays, token),
           plugins = Enum.reject(plugins, &(&1.relay_id in skipped)),
           :ok <- ensure_relays(ns, relays, token),
           :ok <- ensure_plugins(ns, plugins, token) do
        Node.monitor(node, true)

        relay_ids = Enum.map_join(relays, ", ", & &1.id)
        plugin_names = Enum.map_join(plugins, ", ", & &1.name)

        Logger.info("[DevSetup] Testnet ready: relays=[#{relay_ids}], plugins=[#{plugin_names}]")

        %{state | ready: true}
      else
        {:node, nil} ->
          schedule_retry(retries, "waiting for controller node")
          %{state | retries: retries + 1}

        {:error, reason} ->
          schedule_retry(retries, inspect(reason))
          %{state | retries: retries + 1}
      end
    catch
      kind, reason ->
        Logger.warning(
          "[DevSetup] Attempt #{retries + 1} crashed: " <>
            Exception.format(kind, reason, __STACKTRACE__)
        )

        schedule_retry(retries, "crash")
        %{state | retries: retries + 1}
    end
  end

  # Two separate facts: the namespace is *declared* (an object with quotas and
  # role bindings) and a hub is *running* for it. Seeding needs the hub, which
  # comes up when its runner connects; declaring it is what gives the
  # namespace screens real quota data.
  defp ensure_namespace(ns, quotas, token) do
    with :ok <- declare_namespace(ns, quotas, token),
         {:ok, %{rows: catalog}} <- NodeManager.list_namespaces(token) do
      if Enum.any?(catalog, &(to_string(&1.namespace) == ns and &1.running)),
        do: :ok,
        else: {:error, {:namespace_not_running, ns}}
    end
  end

  defp declare_namespace(ns, quotas, token) do
    case NodeManager.create_namespace(ns, quotas, token) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        case NodeManager.error(reason) do
          # Declared on a previous boot — the declaration is left alone.
          %{code: "namespace.already_exists"} ->
            :ok

          %{class: :denied, message: message} ->
            Logger.warning(
              "[DevSetup] Controller refused to declare #{ns}: #{message}. " <>
                "Namespace quotas will read as undeclared."
            )

            :ok

          _failure ->
            {:error, {:declare_namespace, ns, reason}}
        end
    end
  end

  # An optional seed whose factory no runner announces is left out, so an
  # older runner seeds everything else rather than retrying until it gives up.
  # The kept seeds lose the flag, which is the seed's and not the controller's.
  defp drop_unannounced(ns, relays, token) do
    if Enum.any?(relays, & &1[:optional]) do
      with {:ok, %{rows: factories}} <- NodeManager.factories(ns, token) do
        known = MapSet.new(factories, &to_string(&1.id))

        {kept, skipped} =
          Enum.split_with(
            relays,
            &(&1[:optional] != true or MapSet.member?(known, &1.factory_id))
          )

        for relay <- skipped do
          Logger.warning(
            "[DevSetup] Skipped #{relay.id}: no runner announces factory #{relay.factory_id}"
          )
        end

        {:ok, Enum.map(kept, &Map.delete(&1, :optional)), Enum.map(skipped, & &1.id)}
      end
    else
      {:ok, Enum.map(relays, &Map.delete(&1, :optional)), []}
    end
  end

  # A relay already running answers `outcome: :already_running`, so a start
  # per seed is idempotent; the listing only saves the calls.
  defp ensure_relays(ns, relays, token) do
    running =
      ns
      |> NodeManager.relay_list(token, limit: 500, filter: [ids: Enum.map(relays, & &1.id)])
      |> NodeManager.ok_or([])
      |> MapSet.new(& &1.id)

    each_ok(relays, fn relay ->
      if MapSet.member?(running, relay.id) do
        :ok
      else
        case NodeManager.start_relay(ns, relay, token) do
          {:ok, _started} -> :ok
          error -> {:error, {:start_relay, relay.id, error}}
        end
      end
    end)
  end

  # Enabled through the same call the relay screen's attach form makes, every
  # boot: a plugin already enabled answers `outcome: :already_enabled` and is
  # bound to its relay all the same, so a seed whose binding was lost is
  # repaired rather than skipped.
  defp ensure_plugins(ns, plugins, token) do
    each_ok(plugins, fn plugin ->
      fields = %{
        provider: plugin.provider,
        opts: plugin.opts,
        namespace: ns,
        relay_id: plugin.relay_id,
        hooks: plugin.hooks
      }

      case NodeManager.enable_plugin(plugin.name, fields, token) do
        {:ok, %{outcome: :already_enabled}} -> apply_seed_opts(ns, plugin, token)
        {:ok, _answer} -> :ok
        error -> {:error, {:enable_plugin, plugin.name, error}}
      end
    end)
  end

  # A plugin enabled on an earlier boot keeps the options it was enabled with,
  # so an edited seed is applied over them; equal options change nothing.
  defp apply_seed_opts(ns, plugin, token) do
    case NodeManager.update_plugin(plugin.name, %{namespace: ns, opts: plugin.opts}, token) do
      {:ok, _applied} -> :ok
      error -> {:error, {:update_plugin, plugin.name, error}}
    end
  end

  # `fun` over each seed in order, stopping at the first that does not answer `:ok`.
  defp each_ok(seeds, fun) do
    Enum.reduce_while(seeds, :ok, fn seed, :ok ->
      case fun.(seed) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp schedule_retry(retries, reason) do
    Logger.debug("[DevSetup] Attempt #{retries + 1}/#{@max_retries}: #{reason}")
    Process.send_after(self(), :retry, @retry_interval)
  end
end
