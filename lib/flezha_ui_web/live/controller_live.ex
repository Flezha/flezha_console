defmodule FlezhaUiWeb.ControllerLive do
  @moduledoc """
  "Is this controller healthy?" — durability posture, RPO breaches, the
  shipper, shutdown and boot state, and the authorization posture. An admin can
  also drain and stop the controller from here and watch it go.

  Everything here is a controller-wide fact rather than a namespace one, which
  is why it is its own screen rather than a panel on another.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000

  alias FlezhaUi.Service.EventFeed
  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> assign(
       page_title: "Controller",
       memory: nil,
       memory_error: nil,
       memory_loading: false,
       stop: nil
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

  # A stop under way keeps its dialog: reopening would orphan its answer.
  def handle_event("open_stop", _params, %{assigns: %{stop: %{step: :running}}} = socket),
    do: {:noreply, socket}

  def handle_event("open_stop", _params, socket) do
    node = NodeManager.connected_node()

    stop =
      if node,
        do: %{
          step: :confirm,
          target: node,
          node: Atom.to_string(node),
          typed: "",
          force: false,
          timeout_s: ""
        },
        else: nil

    {:noreply, assign(socket, stop: stop)}
  end

  def handle_event("cancel_stop", _params, %{assigns: %{stop: %{step: step}}} = socket)
      when step != :running do
    {:noreply, assign(socket, stop: nil)}
  end

  def handle_event(
        "stop_change",
        %{"stop" => params},
        %{assigns: %{stop: %{step: :confirm}}} = socket
      ) do
    stop = %{
      socket.assigns.stop
      | typed: params["typed"] || "",
        force: params["force"] == "true",
        timeout_s: params["timeout_s"] || ""
    }

    {:noreply, assign(socket, stop: stop)}
  end

  def handle_event(
        "confirm_stop",
        _params,
        %{assigns: %{stop: %{step: :confirm} = stop}} = socket
      ) do
    if armed?(stop) do
      {:noreply, start_stop(socket, stop)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(event, _params, socket)
      when event in ~w(cancel_stop stop_change confirm_stop) do
    {:noreply, socket}
  end

  # Each shutdown phase as core announces it; the dialog lists them in order.
  @impl true
  def handle_info(
        {:feed_event, :controller_stop, event},
        %{assigns: %{stop: %{step: :running} = stop}} = socket
      ) do
    stop = %{stop | events: stop.events ++ [event], phase: phase_of(event) || stop.phase}
    {:noreply, assign(socket, stop: stop)}
  end

  # The stop's own answer, or the stream's end. A controller that goes away
  # once a stop was asked for has stopped; that is the outcome, not a failure.
  def handle_info(
        {kind, :controller_stop, result},
        %{assigns: %{stop: %{step: :running} = stop}} = socket
      )
      when kind in [:feed_ended, :feed_error] do
    result = if kind == :feed_error, do: {:error, result}, else: result
    {:noreply, assign(socket, stop: finish_stop(stop, result))}
  end

  def handle_info({_kind, :controller_stop, _payload}, socket), do: {:noreply, socket}

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
  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token
    {status, status_error} = NodeManager.ok_or_error(NodeManager.controller_status(token), nil)
    {boot, boot_error} = NodeManager.ok_or_error(NodeManager.boot_status(token), nil)
    {shipper, shipper_error} = NodeManager.ok_or_error(NodeManager.durability_status(token), [])

    socket
    |> assign(
      status: status,
      status_error: status_error,
      breaches: token |> NodeManager.durability_breaches() |> NodeManager.ok_or([]),
      shipper: shipper,
      shipper_error: shipper_error,
      boot: boot,
      boot_error: boot_error,
      authz: NodeManager.authz_status(token)
    )
    |> follow_shutdown()
  end

  @doc """
  Whether the stop dialog may confirm: the node is typed exactly and the drain
  timeout is empty or a whole number of seconds.
  """
  def armed?(stop), do: stop.typed == stop.node and timeout_ms(stop.timeout_s) != :invalid

  defp timeout_ms(""), do: nil

  defp timeout_ms(text) do
    case Integer.parse(String.trim(text)) do
      {seconds, ""} when seconds > 0 -> seconds * 1_000
      _ -> :invalid
    end
  end

  defp start_stop(socket, stop) do
    opts =
      case timeout_ms(stop.timeout_s) do
        ms when is_integer(ms) -> [timeout_ms: ms]
        nil -> []
      end

    opts = if stop.force, do: Keyword.put(opts, :force, true), else: opts

    token = socket.assigns.flezha_token

    # The feed reports a refusal to open the same way as a stream that lost its
    # node, so a node already gone is refused here rather than read as stopped.
    if stop.target == NodeManager.connected_node() do
      {:ok, _feed} =
        EventFeed.start_link(
          open: &NodeManager.stop_controller(stop.target, opts, token, &1),
          to: {:send, self(), :controller_stop}
        )

      running = %{step: :running, events: [], phase: nil, started_ms: now_ms()}
      assign(socket, stop: Map.merge(stop, running))
    else
      assign(socket, stop: Map.merge(stop, %{step: :failed, error: :node_not_connected}))
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp finish_stop(stop, result) do
    elapsed_ms = now_ms() - stop.started_ms

    case result do
      {:ok, answer} ->
        Map.merge(stop, %{step: :stopped, outcome: answer[:outcome], elapsed_ms: elapsed_ms})

      {:error, :node_not_connected} ->
        Map.merge(stop, %{step: :stopped, outcome: :disconnected, elapsed_ms: elapsed_ms})

      {:error, reason} ->
        Map.merge(stop, %{step: :failed, error: reason, elapsed_ms: elapsed_ms})
    end
  end

  # While a stop runs, the phase is read from the coordinator itself on every
  # tick, so the dialog moves even between the phases core announces.
  defp follow_shutdown(%{assigns: %{stop: %{step: :running} = stop}} = socket) do
    case NodeManager.shutdown_status(socket.assigns.flezha_token) do
      {:ok, %{shutdown_phase: phase}} when not is_nil(phase) ->
        assign(socket, stop: %{stop | phase: phase})

      _ ->
        socket
    end
  end

  defp follow_shutdown(socket), do: socket

  defp phase_of({:progress, [:flezha, :shutdown, :phase_started], _measurements, meta}),
    do: meta[:phase]

  defp phase_of(_event), do: nil

  @doc "A progress event from a stop, as one line."
  def progress_line({:progress, [:flezha, :shutdown, step], measurements, meta}) do
    phase = meta[:phase] && " #{meta[:phase]}"

    detail =
      measurements
      |> Map.take([:duration_ms, :remaining, :drained])
      |> Enum.map_join(", ", fn {key, value} -> "#{key} #{value}" end)

    "#{step}#{phase}" <> if(detail == "", do: "", else: " (#{detail})")
  end

  def progress_line({:stopped, {:ok, answer}, elapsed_ms}),
    do: "stopped: #{answer[:outcome]} after #{Format.duration(elapsed_ms)}"

  def progress_line({:stopped, {:error, reason}, _elapsed_ms}),
    do: "stop failed: #{inspect(reason)}"

  def progress_line(other), do: inspect(other)

  # Stopping the controller ends every relay it hosts, so the node is typed
  # out before the confirm control arms, and the dialog stays until the stop
  # has an outcome.
  attr :stop, :map, required: true

  defp stop_dialog(assigns) do
    ~H"""
    <.dialog
      testid="stop-controller-modal"
      size="form"
      on_close={@stop.step != :running && "cancel_stop"}
      close_testid="stop-controller-close"
    >
      <:title>Stop controller</:title>

      <form
        :if={@stop.step == :confirm}
        id="stop-controller-form"
        data-testid="stop-controller-form"
        phx-change="stop_change"
        phx-submit="confirm_stop"
        class="space-y-4"
      >
        <p>
          This drains <.ident value={@stop.node} full /> and stops it. Its relays move to the other
          controllers, or stop if there are none. The console loses this controller until it is
          started again.
        </p>
        <.input
          type="number"
          name="stop[timeout_s]"
          label="Drain timeout (seconds)"
          hint="A whole number of seconds; leave empty for the controller's own setting"
          value={@stop.timeout_s}
          min="1"
          data-testid="stop-timeout"
        />
        <.input
          type="checkbox"
          name="stop[force]"
          label="Force: skip the quiesce and the drain, finalise only"
          checked={@stop.force}
          data-testid="stop-force"
        />
        <.input
          type="text"
          name="stop[typed]"
          label={"Type #{@stop.node} to confirm"}
          value={@stop.typed}
          mono
          autocomplete="off"
          data-testid="stop-typed"
        />
      </form>

      <div :if={@stop.step in [:running, :stopped]} class="space-y-3">
        <p data-testid="stop-state">
          <%= if @stop.step == :running do %>
            Stopping <.ident value={@stop.node} full />:
            <span data-testid="stop-phase">
              {(@stop.phase && Words.text(:shutdown_phase, @stop.phase)) || "Starting"}
            </span>
          <% else %>
            <.ident value={@stop.node} full />
            stopped ({Words.humanize(@stop.outcome) |> String.downcase()})
            after {Format.duration(@stop.elapsed_ms)}; its last phase was <span data-testid="stop-phase">{(@stop.phase && Words.text(:shutdown_phase, @stop.phase)) || "—"}</span>.
          <% end %>
        </p>
        <pre :if={@stop.events != []} data-testid="stop-progress" class="fui-code"><span :for={event <- @stop.events} class="block">{progress_line(event)}</span></pre>
      </div>

      <div :if={@stop.step == :failed} data-testid="stop-failed">
        <.runtime_error error={@stop.error} action="the stop" />
      </div>

      <:actions>
        <.button
          :if={@stop.step == :confirm}
          variant="ghost"
          phx-click="cancel_stop"
          data-testid="stop-cancel"
        >
          Cancel
        </.button>
        <.button
          :if={@stop.step == :confirm}
          variant="danger"
          type="submit"
          form="stop-controller-form"
          disabled={!armed?(@stop)}
          data-testid="stop-confirm"
        >
          Stop controller
        </.button>
        <.button
          :if={@stop.step in [:stopped, :failed]}
          variant="ghost"
          phx-click="cancel_stop"
          data-testid="stop-done"
        >
          Close
        </.button>
      </:actions>
    </.dialog>
    """
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
