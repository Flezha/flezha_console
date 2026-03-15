defmodule FlezhaUi.Service.StreamBridge do
  @moduledoc """
  GenServer that bridges a processor's monitored I/O stream to Phoenix PubSub.

  One bridge per (namespace, processor_id, io_type) stream. Multiple LiveView
  subscribers share one bridge (reference-counted). The bridge enables a
  MonitoredIOForward plugin via RPC and broadcasts received messages.
  """

  use GenServer, restart: :temporary
  require Logger

  alias FlezhaUi.Service.NodeManager

  @pubsub FlezhaUi.PubSub

  # ---- Public API ----

  def topic(ns, proc_id, io_type), do: "stream:#{ns}:#{proc_id}:#{io_type}"

  def subscribe(ns, proc_id, io_type) do
    topic = topic(ns, proc_id, io_type)

    case DynamicSupervisor.start_child(
           FlezhaUi.StreamSupervisor,
           {__MODULE__, {ns, proc_id, io_type}}
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning("[StreamBridge] Could not start bridge: #{inspect(reason)}")
        :ok
    end

    Phoenix.PubSub.subscribe(@pubsub, topic)
    GenServer.cast(via(ns, proc_id, io_type), {:add_subscriber, self()})
    topic
  end

  def unsubscribe(ns, proc_id, io_type) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(ns, proc_id, io_type))

    case GenServer.whereis(via(ns, proc_id, io_type)) do
      nil -> :ok
      _pid -> GenServer.cast(via(ns, proc_id, io_type), {:remove_subscriber, self()})
    end
  end

  # ---- Supervisor child spec ----

  def start_link({ns, proc_id, io_type}) do
    GenServer.start_link(__MODULE__, {ns, proc_id, io_type}, name: via(ns, proc_id, io_type))
  end

  # ---- GenServer callbacks ----

  @impl true
  def init({ns, proc_id, io_type}) do
    plugin_id = "stream_#{ns}_#{proc_id}_#{io_type}"

    state = %{
      ns: ns,
      proc_id: proc_id,
      io_type: io_type,
      plugin_id: plugin_id,
      subscribers: MapSet.new(),
      enabled: false
    }

    {:ok, state, {:continue, :enable_plugin}}
  end

  @impl true
  def handle_continue(:enable_plugin, state) do
    trigger = if state.io_type == "input", do: "on_input", else: "on_output"

    plugin_map = %{
      namespace: state.ns,
      processor_id: state.proc_id,
      trigger: trigger,
      position: 999,
      provider_id: "monitored_io_forward",
      provider_settings: %{recv_pid: self()}
    }

    case NodeManager.enable_plugin(state.plugin_id, plugin_map) do
      {:ok, _} ->
        Logger.info("[StreamBridge] Enabled plugin #{state.plugin_id}")
        {:noreply, %{state | enabled: true}}

      {:error, reason} ->
        Logger.warning("[StreamBridge] Could not enable plugin: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:add_subscriber, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_cast({:remove_subscriber, pid}, state) do
    new_subs = MapSet.delete(state.subscribers, pid)
    state = %{state | subscribers: new_subs}

    if MapSet.size(new_subs) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:message_forward, {message, metadata}}, state) do
    msg = %{
      message: format_message(message),
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(state.ns, state.proc_id, state.io_type),
      {:stream_message, msg}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:heartbeat_keepalive, pid}, state) do
    send(pid, :keepalive_ack)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subs = MapSet.delete(state.subscribers, pid)
    state = %{state | subscribers: new_subs}

    if MapSet.size(new_subs) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.enabled do
      NodeManager.disable_plugin(state.plugin_id)
    end

    :ok
  end

  # ---- Helpers ----

  defp via(ns, proc_id, io_type) do
    {:via, Registry, {FlezhaUi.StreamRegistry, {ns, proc_id, io_type}}}
  end

  defp format_message(msg) when is_binary(msg) do
    case String.valid?(msg) do
      true -> msg
      false -> Base.encode16(msg)
    end
  end

  defp format_message(msg), do: inspect(msg)
end
