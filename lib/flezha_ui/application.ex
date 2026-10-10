defmodule FlezhaUi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Owned by the application master, which outlives every request, so the
    # cached identities survive a supervised child restarting.
    FlezhaUi.Service.NodeManager.init_cache()

    children =
      [
        FlezhaUiWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:flezha_ui, :dns_cluster_query) || :ignore},
        FlezhaUi.Service.NodeConnector,
        FlezhaUi.Repo,
        {Phoenix.PubSub, name: FlezhaUi.PubSub},
        {Finch, name: FlezhaUi.Finch}
      ] ++
        event_feed_children() ++
        dev_children() ++
        [
          FlezhaUiWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: FlezhaUi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    FlezhaUiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Left out under `:test`, where tests start their own feeds against a peer
  # node. A supervised singleton would otherwise tail whichever peer happened
  # to be connected, racing the test that owns that peer.
  defp event_feed_children do
    if Application.get_env(:flezha_ui, :start_event_feed, true) do
      FlezhaUi.Service.EventFeed.signal_child_specs()
    else
      []
    end
  end

  defp dev_children, do: dev_setup_children() ++ config_watcher_children()

  # Only the VM serving the console: an `iex -S mix` in the same container
  # would otherwise be stopped too.
  @doc false
  def config_watcher_children do
    if Application.get_env(:flezha_ui, :restart_on_config_change, false) and
         Phoenix.Endpoint.server?(:flezha_ui, FlezhaUiWeb.Endpoint),
       do: [FlezhaUi.Service.ConfigWatcher],
       else: []
  end

  defp dev_setup_children do
    case Application.get_env(:flezha_ui, :dev_setup) do
      %{enabled: true} ->
        [FlezhaUi.Service.DevSetup]

      [{:enabled, true} | _] ->
        [FlezhaUi.Service.DevSetup]

      config when is_list(config) ->
        if config[:enabled], do: [FlezhaUi.Service.DevSetup], else: []

      _ ->
        []
    end
  end
end
