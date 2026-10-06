defmodule FlezhaUiWeb.ControllerLive do
  @moduledoc """
  "Is this controller healthy?" — durability posture, RPO breaches, shutdown
  and boot state, and the authorization posture.

  Everything here is a controller-wide fact rather than a namespace one, which
  is why it is its own screen rather than a panel on another.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> assign(page_title: "Controller", memory: nil, memory_error: nil)
     |> refresh()}
  end

  # Deliberately not on the tick: a process scan is far too expensive to run
  # every few seconds for a screen nobody may be reading.
  @impl true
  def handle_event("memory_snapshot", _params, socket) do
    case NodeManager.mem_top(socket.assigns.flezha_token) do
      {:ok, snapshot} -> {:noreply, assign(socket, memory: snapshot, memory_error: nil)}
      {:error, reason} -> {:noreply, assign(socket, memory: nil, memory_error: reason)}
    end
  end

  # One status read answers the durability posture and the shutdown state; a
  # refused or unavailable read is stated on its panel and the rest renders.
  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token
    {status, status_error} = NodeManager.ok_or_error(NodeManager.controller_status(token), nil)
    {boot, boot_error} = NodeManager.ok_or_error(NodeManager.boot_status(token), nil)

    assign(socket,
      status: status,
      status_error: status_error,
      breaches: token |> NodeManager.durability_breaches() |> NodeManager.ok_or([]),
      boot: boot,
      boot_error: boot_error,
      authz: NodeManager.authz_status(token)
    )
  end

  @doc "A backend name as text, whether it is an atom or a `{module, opts}` pair."
  def backend_label({module, _opts}), do: inspect(module)
  def backend_label(backend) when is_atom(backend), do: to_string(backend)
  def backend_label(other), do: inspect(other)
end
