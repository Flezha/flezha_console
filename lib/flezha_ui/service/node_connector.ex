defmodule FlezhaUi.Service.NodeConnector do
  @moduledoc """
  Automatically connects to the configured flezha Erlang node and
  reconnects whenever the connection is lost.

  Configure the target node via the FLEZHA_NODE environment variable
  (e.g. "flezha@flezha_agent_dev"). Defaults to the value set in
  application config (:flezha_ui, :flezha_node).
  """

  use GenServer
  require Logger

  @default_retry_interval_ms 3_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    node = target_node()
    Logger.info("[NodeConnector] Will connect to #{node}")
    {:ok, %{node: node}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    attempt_connect(state.node)
    {:noreply, state}
  end

  @impl true
  def handle_info(:retry, state) do
    attempt_connect(state.node)
    {:noreply, state}
  end

  # Called by the Erlang node monitor when a node goes down
  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("[NodeConnector] Node #{node} went down, will retry in #{retry_interval()}ms")

    schedule_retry()
    {:noreply, state}
  end

  defp attempt_connect(node) do
    case Node.connect(node) do
      true ->
        Logger.info("[NodeConnector] Connected to #{node}")
        Node.monitor(node, true)

      false ->
        Logger.warning(
          "[NodeConnector] Could not connect to #{node}, retrying in #{retry_interval()}ms"
        )

        schedule_retry()

      :ignored ->
        Logger.error(
          "[NodeConnector] Distribution not started — check that the VM was started with --sname or --name"
        )
    end
  end

  defp schedule_retry do
    Process.send_after(self(), :retry, retry_interval())
  end

  defp retry_interval,
    do:
      Application.get_env(
        :flezha_ui,
        :node_connector_retry_interval_ms,
        @default_retry_interval_ms
      )

  defp target_node do
    case System.get_env("FLEZHA_NODE") do
      nil -> Application.get_env(:flezha_ui, :flezha_node, :flezha@flezha_agent_dev)
      val -> String.to_atom(val)
    end
  end
end
