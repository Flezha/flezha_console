defmodule FlezhaUi.Service.StreamBridge do
  @moduledoc """
  GenServer that bridges an operative's monitored I/O stream to Phoenix PubSub.

  One bridge per (namespace, operative_id, io_type) stream. Multiple LiveView
  subscribers share one bridge (reference-counted). The bridge enables a
  MonitoredIOForward plugin via RPC and broadcasts received messages.
  """

  use GenServer, restart: :temporary
  require Logger

  alias FlezhaUi.Service.NodeManager

  @pubsub FlezhaUi.PubSub

  # ---- Public API ----

  def topic(ns, operative_id, io_type), do: "stream:#{ns}:#{operative_id}:#{io_type}"

  def subscribe(ns, operative_id, io_type) do
    topic = topic(ns, operative_id, io_type)

    case DynamicSupervisor.start_child(
           FlezhaUi.StreamSupervisor,
           {__MODULE__, {ns, operative_id, io_type}}
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
    GenServer.cast(via(ns, operative_id, io_type), {:add_subscriber, self()})
    topic
  end

  def unsubscribe(ns, operative_id, io_type) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(ns, operative_id, io_type))

    case GenServer.whereis(via(ns, operative_id, io_type)) do
      nil -> :ok
      _pid -> GenServer.call(via(ns, operative_id, io_type), {:remove_subscriber, self()})
    end
  end

  # ---- Supervisor child spec ----

  def start_link({ns, operative_id, io_type}) do
    GenServer.start_link(__MODULE__, {ns, operative_id, io_type},
      name: via(ns, operative_id, io_type)
    )
  end

  # ---- GenServer callbacks ----

  @impl true
  def init({ns, operative_id, io_type}) do
    state = %{
      ns: ns,
      operative_id: operative_id,
      io_type: io_type,
      plugin_id: nil,
      subscribers: MapSet.new(),
      enabled: false
    }

    {:ok, state, {:continue, :enable_plugin}}
  end

  @impl true
  def handle_continue(:enable_plugin, state) do
    case NodeManager.enable_io_listener(state.ns, state.operative_id, state.io_type, self()) do
      {:ok, plugin_id} ->
        Logger.info("[StreamBridge] Enabled plugin #{plugin_id}")
        broadcast_status(state, :connected)
        {:noreply, %{state | plugin_id: plugin_id, enabled: true}}

      {:error, reason} ->
        Logger.warning("[StreamBridge] Could not enable plugin: #{inspect(reason)}")
        broadcast_status(state, {:error, reason})
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:add_subscriber, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_call({:remove_subscriber, pid}, _from, state) do
    new_subs = MapSet.delete(state.subscribers, pid)
    state = %{state | subscribers: new_subs}

    if MapSet.size(new_subs) == 0 do
      cleanup_plugin(state)
      {:stop, :normal, :ok, %{state | enabled: false}}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:message_forward, {message, metadata}}, state) do
    msg = %{
      message: FlezhaUi.Format.printable(message),
      # Sized before it is rendered printable: a non-UTF-8 payload becomes hex,
      # which would report double what actually crossed the wire.
      bytes: payload_bytes(message),
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(state.ns, state.operative_id, state.io_type),
      {:stream_message, msg}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:heartbeat_keepalive, pid}, state) do
    send(pid, {:heartbeat_keepalive, :ok})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subs = MapSet.delete(state.subscribers, pid)
    state = %{state | subscribers: new_subs}

    if MapSet.size(new_subs) == 0 do
      cleanup_plugin(state)
      {:stop, :normal, %{state | enabled: false}}
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

  defp cleanup_plugin(state) do
    if state.enabled do
      NodeManager.disable_plugin(state.plugin_id)
    end
  end

  defp payload_bytes(message) when is_binary(message), do: byte_size(message)
  defp payload_bytes(message), do: message |> :erlang.term_to_binary() |> byte_size()

  defp broadcast_status(state, status) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(state.ns, state.operative_id, state.io_type),
      {:stream_status, status}
    )
  end

  defp via(ns, operative_id, io_type) do
    {:via, Registry, {FlezhaUi.StreamRegistry, {ns, operative_id, io_type}}}
  end
end
