defmodule FlezhaUi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        FlezhaUiWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:flezha_ui, :dns_cluster_query) || :ignore},
        FlezhaUi.Service.NodeConnector,
        FlezhaUi.Repo,
        {Phoenix.PubSub, name: FlezhaUi.PubSub},
        {Finch, name: FlezhaUi.Finch},
        {Registry, keys: :unique, name: FlezhaUi.StreamRegistry},
        {DynamicSupervisor, name: FlezhaUi.StreamSupervisor, strategy: :one_for_one},
        FlezhaUi.Service.EventBridge
      ] ++
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
