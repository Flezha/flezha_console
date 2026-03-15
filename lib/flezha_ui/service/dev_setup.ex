defmodule FlezhaUi.Service.DevSetup do
  @moduledoc """
  Dev-only GenServer that auto-creates testnet processors and plugins
  when the agent node becomes available. Retries every 5s for up to 5 minutes.
  Resets and re-attempts on nodedown.
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
    Logger.warning("[DevSetup] Agent node #{node} went down, will re-attempt on reconnect")
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
    processors = config[:processors] || []
    plugins = config[:plugins] || []

    try do
      with {:node, node} when node != nil <- {:node, NodeManager.connected_node()},
           :ok <- ensure_namespace(ns),
           :ok <- ensure_processors(ns, processors),
           :ok <- ensure_plugins(ns, plugins) do
        Node.monitor(node, true)

        proc_ids = Enum.map_join(processors, ", ", & &1.id)
        plugin_ids = Enum.map_join(plugins, ", ", & &1.plugin_id)

        Logger.info("[DevSetup] Testnet ready: processors=[#{proc_ids}], plugins=[#{plugin_ids}]")

        %{state | ready: true}
      else
        {:node, nil} ->
          schedule_retry(retries, "waiting for agent node")
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

  defp ensure_namespace(ns) do
    namespaces =
      case NodeManager.list_namespaces() do
        {:ok, list} when is_list(list) -> list
        list when is_list(list) -> list
        _ -> nil
      end

    if namespaces do
      if Enum.any?(namespaces, fn n -> to_string(n) == ns end) do
        :ok
      else
        {:error, {:namespace_not_found, ns}}
      end
    else
      {:error, :no_namespaces}
    end
  end

  defp ensure_processors(ns, processors) do
    existing =
      case NodeManager.list_processors(ns) do
        {:ok, list} when is_list(list) -> list
        list when is_list(list) -> list
        _ -> []
      end

    existing_ids = MapSet.new(existing, &to_string/1)

    Enum.reduce_while(processors, :ok, fn proc, :ok ->
      if MapSet.member?(existing_ids, proc.id) do
        {:cont, :ok}
      else
        case NodeManager.start_processor(ns, proc.id, proc.factory_id, proc.init_values) do
          {:ok, _} -> {:cont, :ok}
          :ok -> {:cont, :ok}
          error -> {:halt, {:error, {:start_processor, proc.id, error}}}
        end
      end
    end)
  end

  defp ensure_plugins(ns, plugins) do
    existing =
      case NodeManager.get_plugins() do
        {:ok, p} when is_map(p) -> p
        p when is_map(p) -> p
        _ -> %{}
      end

    existing_ids =
      MapSet.new(Map.keys(existing), &to_string/1)

    Enum.reduce_while(plugins, :ok, fn plugin, :ok ->
      if MapSet.member?(existing_ids, plugin.plugin_id) do
        {:cont, :ok}
      else
        case enable_plugin(ns, plugin) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end
    end)
  end

  defp enable_plugin(ns, plugin) do
    # Use CliManager.enable_plugin/4 on the agent — it handles the full
    # provider_mod.build → IOBindingPlugin.build → PluginManager.enable pipeline.
    # plugin_flags must include processor_id, trigger, position (used by IOBindingPlugin.build)
    # plus provider-specific settings (used by provider.build)
    plugin_flags =
      Map.merge(plugin.provider_settings, %{
        "processor_id" => plugin.processor_id,
        "trigger" => plugin.trigger,
        "position" => to_string(plugin.position)
      })

    plugin_flags_json = Jason.encode!(plugin_flags)
    opts_json = Jason.encode!(%{"namespace" => ns})

    try do
      result =
        NodeManager.erpc_call(
          Flezha.Service.CliManager,
          :enable_plugin,
          [plugin.plugin_id, plugin.provider_id, plugin_flags_json, opts_json]
        )

      case result do
        {:ok, _} -> :ok
        :ok -> :ok
        error -> {:error, error}
      end
    catch
      kind, reason ->
        Logger.warning("[DevSetup] enable_plugin crashed: #{kind} #{inspect(reason)}")
        {:error, {kind, reason}}
    end
  end

  defp schedule_retry(retries, reason) do
    Logger.debug("[DevSetup] Attempt #{retries + 1}/#{@max_retries}: #{reason}")
    Process.send_after(self(), :retry, @retry_interval)
  end
end
