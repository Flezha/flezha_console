defmodule FlezhaUi.Service.DevSetup do
  @moduledoc """
  Dev-only GenServer that auto-creates testnet operatives and plugins
  when the controller node becomes available. Retries every 5s for up to 5
  minutes. Resets and re-attempts on nodedown.

  Idempotent: an operative or plugin that already exists is left alone, so a
  UI restart against a seeded controller is a no-op.
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
    operatives = config[:operatives] || []
    plugins = config[:plugins] || []

    try do
      with {:node, node} when node != nil <- {:node, NodeManager.connected_node()},
           :ok <- ensure_namespace(ns),
           :ok <- ensure_operatives(ns, operatives),
           :ok <- ensure_plugins(ns, plugins) do
        Node.monitor(node, true)

        operative_ids = Enum.map_join(operatives, ", ", & &1.id)
        plugin_ids = Enum.map_join(plugins, ", ", & &1.plugin_id)

        Logger.info(
          "[DevSetup] Testnet ready: operatives=[#{operative_ids}], plugins=[#{plugin_ids}]"
        )

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

  defp ensure_namespace(ns) do
    with {:ok, list} <- NodeManager.list_namespaces() do
      if Enum.any?(list, fn n -> to_string(n) == ns end) do
        :ok
      else
        {:error, {:namespace_not_found, ns}}
      end
    end
  end

  defp ensure_operatives(ns, operatives) do
    existing =
      ns |> NodeManager.list_operatives() |> NodeManager.ok_or([]) |> MapSet.new(&to_string/1)

    Enum.reduce_while(operatives, :ok, fn operative, :ok ->
      if MapSet.member?(existing, operative.id) do
        {:cont, :ok}
      else
        case NodeManager.start_operative(
               ns,
               operative.id,
               operative.factory_id,
               operative.init_values,
               Map.get(operative, :opts, []),
               Map.get(operative, :kind, :stream)
             ) do
          {:ok, _} -> {:cont, :ok}
          :ok -> {:cont, :ok}
          error -> {:halt, {:error, {:start_operative, operative.id, error}}}
        end
      end
    end)
  end

  defp ensure_plugins(ns, plugins) do
    existing =
      case NodeManager.get_plugins() do
        map when is_map(map) -> MapSet.new(Map.keys(map), &to_string/1)
        _ -> MapSet.new()
      end

    providers = NodeManager.ok_or(NodeManager.get_provider_info(), [])

    Enum.reduce_while(plugins, :ok, fn plugin, :ok ->
      if MapSet.member?(existing, plugin.plugin_id) do
        {:cont, :ok}
      else
        case enable_plugin(ns, plugin, providers) do
          {:ok, _} ->
            {:cont, :ok}

          :ok ->
            {:cont, :ok}

          # The desired state already holds. A plugin can be live on the
          # operative while absent from the plugin registry — the operative's
          # subscriptions are restored from its persisted spec, the registry is
          # not — so this is the seeder's goal met, not a failure.
          {:error, {:plugin_already_subscribed, _id}} ->
            {:cont, :ok}

          error ->
            {:halt, {:error, {:enable_plugin, plugin.plugin_id, error}}}
        end
      end
    end)
  end

  # Goes through the same NodeManager path the UI's attach form uses, so the
  # seeded plugins exercise the code an operator drives.
  defp enable_plugin(ns, plugin, providers) do
    case find_provider(providers, plugin.provider_id) do
      nil ->
        {:error, {:provider_not_enabled, plugin.provider_id}}

      provider ->
        form =
          plugin.provider_settings
          |> Map.put("extensions", plugin.extensions)
          |> merge_sub_opts(Map.get(plugin, :sub_opts, %{}))

        NodeManager.enable_plugin(plugin.plugin_id, provider, form, ns, plugin.operative_id)
    end
  end

  defp merge_sub_opts(form, sub_opts) do
    Enum.reduce(sub_opts, form, fn {key, value}, acc ->
      Map.put(acc, "sub_#{key}", to_string(value))
    end)
  end

  defp find_provider(providers, provider_id) do
    Enum.find_value(providers, fn info ->
      if to_string(Map.get(info, :id)) == provider_id do
        %{
          module: Map.get(info, :module),
          required_fields: Map.get(info, :required_fields, []),
          optional_fields: Map.get(info, :optional_fields, [])
        }
      end
    end)
  end

  defp schedule_retry(retries, reason) do
    Logger.debug("[DevSetup] Attempt #{retries + 1}/#{@max_retries}: #{reason}")
    Process.send_after(self(), :retry, @retry_interval)
  end
end
