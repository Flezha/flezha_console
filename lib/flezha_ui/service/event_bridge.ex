defmodule FlezhaUi.Service.EventBridge do
  @moduledoc """
  GenServer that subscribes to Flezha.Service.EventManager events via RPC
  and broadcasts them to Phoenix PubSub topic "flezha:events".
  """

  use GenServer
  require Logger

  @pubsub FlezhaUi.PubSub
  @topic "flezha:events"
  @retry_interval 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def topic, do: @topic

  @impl true
  def init(_opts) do
    {:ok, %{subscribed: false}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    state = attempt_subscribe(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    state = attempt_subscribe(state)
    {:noreply, state}
  end

  # Compute engine connected event
  @impl true
  def handle_info({:compute_engine_connected_event, data}, state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:flezha_event, :compute_engine_connected, data})
    {:noreply, state}
  end

  # Compute engine disconnected event
  @impl true
  def handle_info({:compute_engine_disconnected_event, data}, state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:flezha_event, :compute_engine_disconnected, data})
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[EventBridge] Unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  defp attempt_subscribe(state) do
    node = FlezhaUi.Service.NodeManager.connected_node()

    if node do
      try do
        :erpc.call(node, Flezha.Service.EventManager, :subscribe, [self()])
        Logger.info("[EventBridge] Subscribed to Flezha events on #{node}")
        %{state | subscribed: true}
      catch
        _, reason ->
          Logger.warning("[EventBridge] Could not subscribe: #{inspect(reason)}, retrying in #{@retry_interval}ms")
          Process.send_after(self(), :retry_subscribe, @retry_interval)
          state
      end
    else
      Process.send_after(self(), :retry_subscribe, @retry_interval)
      state
    end
  end
end
