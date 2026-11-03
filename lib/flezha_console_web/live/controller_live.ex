defmodule FlezhaConsoleWeb.ControllerLive do
  @moduledoc """
  "Is this controller healthy?" — every controller of the cluster, and one
  chosen controller's durability posture, RPO breaches, shipper, shutdown and
  boot state, and the authorization posture.

  Everything here is a controller-wide fact rather than a namespace one, which
  is why it is its own screen rather than a panel on another. The listing is
  the chooser: `?controller=` names the chosen one, and the controller this
  console is connected to is chosen when it names none.
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
       asked: nil,
       memory: nil,
       memory_error: nil,
       memory_loading: false
     )}
  end

  # A snapshot belongs to the controller it was taken of, so choosing another
  # one puts it away.
  @impl true
  def handle_params(params, _uri, socket) do
    asked = params["controller"]

    socket =
      if asked == socket.assigns.asked,
        do: socket,
        else: assign(socket, asked: asked, memory: nil, memory_error: nil)

    {:noreply, refresh(socket)}
  end

  # Deliberately not on the tick: a process scan is far too expensive to run
  # every few seconds for a screen nobody may be reading. It takes seconds, so
  # it runs aside while the button says so.
  @impl true
  def handle_event("memory_snapshot", _params, %{assigns: %{memory_loading: true}} = socket),
    do: {:noreply, socket}

  def handle_event("memory_snapshot", _params, socket) do
    %{flezha_token: token, chosen: chosen} = socket.assigns

    {:noreply,
     socket
     |> assign(memory_loading: true)
     |> start_async(:memory_snapshot, fn ->
       token |> NodeManager.mem_top() |> NodeManager.controller_row(chosen)
     end)}
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

  # Each read answers every controller; the chosen one's share fills the
  # panels. A controller that did not answer, or a refused read, is stated on
  # its panel and the rest renders.
  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token
    listed = NodeManager.controllers(token)
    {controllers, controllers_error} = NodeManager.ok_or_error(listed, [])
    chosen = chosen(socket.assigns.asked, controllers)

    reads = %{
      status: NodeManager.controller_status(token),
      boot: NodeManager.boot_status(token),
      shipper: NodeManager.durability_status(token),
      breaches: NodeManager.durability_breaches(token)
    }

    {status, status_error} =
      reads.status |> NodeManager.controller_row(chosen) |> NodeManager.ok_or_error(nil)

    {boot, boot_error} =
      reads.boot |> NodeManager.controller_row(chosen) |> NodeManager.ok_or_error(nil)

    {shipper, shipper_error} =
      reads.shipper |> NodeManager.of_controller(chosen) |> NodeManager.ok_or_error([])

    socket
    |> assign(
      controllers: controllers,
      controllers_error: controllers_error,
      chosen: chosen,
      chosen_row: Enum.find(controllers, &(to_string(&1.node) == chosen)),
      unreachable: NodeManager.unreachable([listed | Map.values(reads)]),
      status: status,
      status_error: status_error,
      breaches: reads.breaches |> NodeManager.of_controller(chosen) |> NodeManager.ok_or([]),
      shipper: shipper,
      shipper_error: shipper_error,
      boot: boot,
      boot_error: boot_error,
      authz: NodeManager.authz_status(token)
    )
  end

  @doc """
  The node name of the chosen controller: the one `asked` names, else the one
  the listing marks as this console's, else the one this console calls.
  """
  def chosen(asked, _controllers) when asked not in [nil, ""], do: asked

  def chosen(_asked, controllers) do
    case Enum.find(controllers, & &1[:local?]) do
      %{node: node} -> to_string(node)
      nil -> to_string(NodeManager.connected_node())
    end
  end

  @doc "The address that chooses `node` on this screen."
  def choose_path(node), do: ~p"/controller?#{[controller: to_string(node)]}"

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
