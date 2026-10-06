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
      [FlezhaUi.Service.EventFeed.runners_child_spec()]
    else
      []
    end
  end

  defp dev_children do
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
