defmodule FlezhaConsole.Service.NodeConnector do
  @moduledoc """
  Connects to the controller node `target_node/0` names (for example
  `FLEZHA_NODE=flezha@flezha_controller`) and reconnects whenever the
  connection is lost.
  """

  use GenServer
  require Logger

  @default_retry_interval_ms 3_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[NodeConnector] Will connect to #{target_node()}")
    {:ok, %{}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    attempt_connect(target_node())
    {:noreply, state}
  end

  @impl true
  def handle_info(:retry, state) do
    attempt_connect(target_node())
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
        :flezha_console,
        :node_connector_retry_interval_ms,
        @default_retry_interval_ms
      )

  @doc """
  The controller node this console talks to: `FLEZHA_NODE`; else, with
  `FLEZHA_NODE_QUERY` (`name@dns-name`), a `name@address` node for an address
  the DNS name resolves to, one already connected first; else the
  `:flezha_node` setting.

  Read on every call rather than kept from boot, so the connector and the seam
  always aim at the node currently configured, and at a replaced controller
  under its new address.
  """
  def target_node do
    case {System.get_env("FLEZHA_NODE"), System.get_env("FLEZHA_NODE_QUERY")} do
      {nil, nil} -> Application.get_env(:flezha_console, :flezha_node, :flezha@flezha_agent_dev)
      {nil, query} -> queried_node(query)
      {node, _query} -> String.to_atom(node)
    end
  end

  # A controller named after its pod address takes a new name with every new
  # pod, so the names are rebuilt from what the DNS name resolves to now.
  defp queried_node(query) do
    [name, host] = String.split(query, "@", parts: 2)

    candidates =
      case :inet.getaddrs(String.to_charlist(host), :inet) do
        {:ok, addresses} -> addresses |> Enum.map(&:"#{name}@#{:inet.ntoa(&1)}") |> Enum.sort()
        {:error, _reason} -> []
      end

    Enum.find(candidates, &(&1 in Node.list(:connected))) || List.first(candidates) ||
      String.to_atom(query)
  end
end
