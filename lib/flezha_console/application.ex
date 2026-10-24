defmodule FlezhaConsole.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Owned by the application master, which outlives every request, so the
    # cached identities survive a supervised child restarting.
    FlezhaConsole.Service.NodeManager.init_cache()

    children =
      [
        FlezhaConsoleWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:flezha_console, :dns_cluster_query) || :ignore},
        FlezhaConsole.Service.NodeConnector,
        FlezhaConsole.Repo,
        {Phoenix.PubSub, name: FlezhaConsole.PubSub},
        {Finch, name: FlezhaConsole.Finch}
      ] ++
        event_feed_children() ++
        dev_children() ++
        [
          FlezhaConsoleWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: FlezhaConsole.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    FlezhaConsoleWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Left out under `:test`, where tests start their own feeds against a peer
  # node. A supervised singleton would otherwise tail whichever peer happened
  # to be connected, racing the test that owns that peer.
  defp event_feed_children do
    if Application.get_env(:flezha_console, :start_event_feed, true) do
      FlezhaConsole.Service.EventFeed.signal_child_specs()
    else
      []
    end
  end

  defp dev_children, do: dev_setup_children() ++ config_watcher_children()

  # Only the VM serving the console: an `iex -S mix` in the same container
  # would otherwise be stopped too.
  @doc false
  def config_watcher_children do
    if Application.get_env(:flezha_console, :restart_on_config_change, false) and
         Phoenix.Endpoint.server?(:flezha_console, FlezhaConsoleWeb.Endpoint),
       do: [FlezhaConsole.Service.ConfigWatcher],
       else: []
  end

  defp dev_setup_children do
    case Application.get_env(:flezha_console, :dev_setup) do
      %{enabled: true} ->
        [FlezhaConsole.Service.DevSetup]

      [{:enabled, true} | _] ->
        [FlezhaConsole.Service.DevSetup]

      config when is_list(config) ->
        if config[:enabled], do: [FlezhaConsole.Service.DevSetup], else: []

      _ ->
        []
    end
  end
end
