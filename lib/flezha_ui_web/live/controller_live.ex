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

  # Deliberately not on the tick: a process scan plus `:recon_alloc` is far too
  # expensive to run every few seconds for a screen nobody may be reading.
  @impl true
  def handle_event("memory_snapshot", _params, socket) do
    case NodeManager.memory_snapshot() do
      %{} = snapshot -> {:noreply, assign(socket, memory: snapshot, memory_error: nil)}
      {:error, reason} -> {:noreply, assign(socket, memory_error: reason)}
      other -> {:noreply, assign(socket, memory_error: {:remote_error, other})}
    end
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    assign(socket,
      backend: NodeManager.durability_backend(),
      posture: NodeManager.durability_posture(),
      breaches: NodeManager.ok_or(NodeManager.durability_breaches(), []),
      shipments: NodeManager.ok_or(NodeManager.durability_status(), []),
      shutdown: shutdown(),
      boot: NodeManager.ok_or(NodeManager.boot_status(), []),
      authz: NodeManager.authz_status(socket.assigns.flezha_token)
    )
  end

  # One unavailable panel must not take the screen down with it.
  defp shutdown do
    case NodeManager.shutdown_status() do
      %{} = status -> status
      _unavailable -> nil
    end
  end

  @doc "Shipments another writer has taken over — a fact, not necessarily a fault."
  def superseded(shipments), do: Enum.count(shipments, &Map.get(&1, :superseded_by))

  @doc "A backend name as text, whether it is an atom or a `{module, opts}` pair."
  def backend_label({module, _opts}), do: inspect(module)
  def backend_label(backend) when is_atom(backend), do: to_string(backend)
  def backend_label(other), do: inspect(other)
end
