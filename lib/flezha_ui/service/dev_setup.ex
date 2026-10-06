defmodule FlezhaUi.Service.DevSetup do
  @moduledoc """
  Dev-only GenServer that seeds testnet relays and plugins through the
  published API, with the service token, when the controller node becomes
  available. Retries every 5s for up to 5 minutes. Resets and re-attempts on
  nodedown.

  Idempotent: a relay already running is left alone, and a plugin already
  enabled answers `already_enabled`, so a UI restart against a seeded
  controller changes nothing.
  """

  use GenServer
  require Logger

  alias FlezhaUi.Service.NodeManager

  @retry_interval 5_000
  @max_retries 60

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:flezha_ui, :dev_setup)
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
    token = FlezhaUi.Accounts.service_flezha_token()

    try do
      with {:node, node} when node != nil <- {:node, NodeManager.connected_node()},
           :ok <- ensure_namespace(ns, config[:quotas] || %{}, token),
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
        Logger.warning("[DevSetup] Attempt #{retries + 1} crashed: #{kind} #{inspect(reason)}")
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
         {:ok, catalog} <- NodeManager.list_namespaces(token) do
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

  # A relay already running answers `outcome: :already_running`, so a start
  # per seed is idempotent; the listing only saves the calls.
  defp ensure_relays(ns, relays, token) do
    running = ns |> NodeManager.list_relays(token) |> NodeManager.ok_or([]) |> MapSet.new()

    Enum.reduce_while(relays, :ok, fn relay, :ok ->
      if MapSet.member?(running, relay.id) do
        {:cont, :ok}
      else
        case NodeManager.start_relay(ns, relay, token) do
          {:ok, _started} -> {:cont, :ok}
          error -> {:halt, {:error, {:start_relay, relay.id, error}}}
        end
      end
    end)
  end

  # Enabled through the same call the relay screen's attach form makes, every
  # boot: a plugin already enabled answers `outcome: :already_enabled` and is
  # bound to its relay all the same, so a seed whose binding was lost is
  # repaired rather than skipped.
  defp ensure_plugins(ns, plugins, token) do
    Enum.reduce_while(plugins, :ok, fn plugin, :ok ->
      fields = %{
        provider: plugin.provider,
        opts: plugin.opts,
        namespace: ns,
        relay_id: plugin.relay_id,
        hooks: plugin.hooks
      }

      case NodeManager.enable_plugin(plugin.name, fields, token) do
        {:ok, _answer} -> {:cont, :ok}
        error -> {:halt, {:error, {:enable_plugin, plugin.name, error}}}
      end
    end)
  end

  defp schedule_retry(retries, reason) do
    Logger.debug("[DevSetup] Attempt #{retries + 1}/#{@max_retries}: #{reason}")
    Process.send_after(self(), :retry, @retry_interval)
  end
end
