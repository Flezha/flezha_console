defmodule FlezhaConsoleWeb.ControllerLive do
  @moduledoc """
  "Is this controller healthy?" — the controllers connected with it,
  durability posture, RPO breaches, the shipper, shutdown and boot state, and
  the authorization posture.

  Everything here is a controller-wide fact rather than a namespace one, which
  is why it is its own screen rather than a panel on another.
  """

  use FlezhaConsoleWeb, :live_view

  use FlezhaConsoleWeb.Live.Refresh, every: 5_000

  alias FlezhaConsole.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> assign(
       page_title: "Controller",
       memory: nil,
       memory_error: nil,
       memory_loading: false
     )
     |> refresh()}
  end

  # Deliberately not on the tick: a process scan is far too expensive to run
  # every few seconds for a screen nobody may be reading. It takes seconds, so
  # it runs aside while the button says so.
  @impl true
  def handle_event("memory_snapshot", _params, %{assigns: %{memory_loading: true}} = socket),
    do: {:noreply, socket}

  def handle_event("memory_snapshot", _params, socket) do
    token = socket.assigns.flezha_token

    {:noreply,
     socket
     |> assign(memory_loading: true)
     |> start_async(:memory_snapshot, fn -> NodeManager.mem_top(token) end)}
  end

  # A scan that crashed is a failure like a refused one.
  @impl true
  def handle_async(:memory_snapshot, result, socket) do
    socket = assign(socket, memory_loading: false)

    socket =
      case with({:ok, answer} <- result, do: answer) do
        {:ok, snapshot} ->
          socket
          |> assign(memory: snapshot, memory_error: nil)
          |> put_flash(:info, "Memory snapshot taken.")

        {_failed, reason} ->
          assign(socket, memory: nil, memory_error: reason)
      end

    {:noreply, reveal(socket, "memory-panel")}
  end

  # One status read answers the durability posture and the shutdown state; a
  # refused or unavailable read is stated on its panel and the rest renders.
  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token
    {status, status_error} = NodeManager.ok_or_error(NodeManager.controller_status(token), nil)
    {boot, boot_error} = NodeManager.ok_or_error(NodeManager.boot_status(token), nil)
    {shipper, shipper_error} = NodeManager.ok_or_error(NodeManager.durability_status(token), [])
    {controllers, controllers_error} = NodeManager.ok_or_error(NodeManager.controllers(token), [])

    socket
    |> assign(
      controllers: controllers,
      controllers_error: controllers_error,
      status: status,
      status_error: status_error,
      breaches: token |> NodeManager.durability_breaches() |> NodeManager.ok_or([]),
      shipper: shipper,
      shipper_error: shipper_error,
      boot: boot,
      boot_error: boot_error,
      authz: NodeManager.authz_status(token)
    )
  end

  @doc """
  "2 controllers connected: rpi5 and raspberrypi4", naming the machine each
  runs on, from `NodeManager.controllers/1`'s rows; nothing for none. With `link`, it leads to the Controller screen.
  """
  attr :controllers, :any, required: true
  attr :link, :boolean, default: false
  attr :testid, :string, default: "controllers-connected"

  def connected(assigns) do
    ~H"""
    <span :if={@controllers != []} data-testid={@testid}>
      <.link :if={@link} navigate={~p"/controller"}>{connected_words(@controllers)}</.link>
      <span :if={!@link}>{connected_words(@controllers)}</span>
    </span>
    """
  end

  defp connected_words(rows) do
    machines =
      Enum.map(rows, fn row ->
        machine(row) <>
          if(row.reachable?, do: "", else: " (not answering)")
      end)

    "#{Words.count(length(rows), "controller")} connected: #{Words.join(machines)}"
  end

  @doc "The machine a `NodeManager.controllers/1` row runs on, or its host when it does not say."
  def machine(%{host_node: "" <> machine}), do: machine
  def machine(%{host: "" <> host}), do: host
  def machine(%{node: node}), do: node |> to_string() |> String.split("@") |> List.last()

  @doc "A backend name in words, whether it is an atom or a `{module, opts}` pair."
  def backend_label({module, _opts}), do: Words.humanize(module)
  def backend_label(nil), do: "None"
  def backend_label(backend), do: Words.humanize(backend)

  @doc "The controller's condition in one sentence: readiness, authorization, durability."
  def sentence(boot, authz, status) do
    readiness = boot && Words.text(:readiness, boot.readiness)
    posture = authz.posture && Words.text(:authz_posture, authz.posture)
    durability = status && Words.text(:durability_posture, status[:durability_posture])

    [
      readiness && "It is #{String.downcase(readiness)}.",
      posture && "Authorization is #{Words.in_sentence(posture)}.",
      durability && "#{durability}."
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end
end
