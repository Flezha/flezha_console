defmodule FlezhaUiWeb.River do
  @moduledoc """
  The event river: what this console saw happen while a screen was open,
  newest first, over a 15-minute time track.

  It holds relay lifecycle signals, runner session events and attention items
  appearing and clearing, at most the fifty most recent, each narrowed to the
  namespaces the operator's token reaches and, on a namespace's screen, to that
  namespace. It is not history the controller kept: it starts empty with the
  screen.

      use FlezhaUiWeb.River

      def mount(_params, _session, socket) do
        {:ok, socket |> start_refresh() |> river_init()}
      end

  The host renders `river/1` with `@river`. Lifecycle signals arrive on their
  own topic and reload the host's rows; runner events ride the host's
  `FlezhaUiWeb.Live.Refresh` subscription; attention diffs are pushed by the
  host with `attention/3`.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.EventFeed

  @max 50
  @window_s 15 * 60
  @lifecycle [:relay_started, :relay_stopped, :relay_exited]

  defmacro __using__(_opts) do
    lifecycle = @lifecycle

    quote do
      import FlezhaUiWeb.River, only: [river_init: 1, river: 1]

      @impl Phoenix.LiveView
      def handle_info({:flezha_event, event, {namespace, entry}}, socket)
          when event in unquote(lifecycle) do
        case FlezhaUiWeb.River.lifecycle(socket, namespace, entry) do
          ^socket -> {:noreply, socket}
          socket -> {:noreply, FlezhaUiWeb.Live.Refresh.tick(__MODULE__, socket)}
        end
      end

      def handle_info({:flezha_feed, _feed, error}, socket),
        do: {:noreply, Phoenix.Component.assign(socket, river_error: error)}
    end
  end

  @doc """
  Initial assigns for a host, and its subscription to the relay lifecycle
  feed. Only once connected: the dead render has no feed to hear from.
  """
  def river_init(socket) do
    error =
      if Phoenix.LiveView.connected?(socket) do
        Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic(:flezha_relay))
        EventFeed.error(EventFeed.signal_feed(:flezha_relay))
      end

    assign(socket, river: [], river_error: error)
  end

  @doc """
  Puts a lifecycle signal on the river when the screen shows its namespace.
  Answers the socket unchanged otherwise.
  """
  def lifecycle(socket, nil, _entry), do: socket

  def lifecycle(socket, namespace, entry) do
    push(socket, namespace, %{
      at: entry.at,
      namespace: to_string(namespace),
      object: entry.relay && to_string(entry.relay),
      path:
        entry.relay && ~p"/namespaces/#{to_string(namespace)}/relays/#{to_string(entry.relay)}",
      text: lifecycle_text(entry),
      tone: if(entry.event == :relay_exited, do: :warning, else: :signal),
      kind: entry.event
    })
  end

  @doc "Puts a runner session event on the river, for a host that keeps one."
  def runner(%{assigns: %{river: _}} = socket, event, {namespace, runner})
      when not is_nil(namespace) do
    push(socket, namespace, %{
      at: DateTime.utc_now(),
      namespace: to_string(namespace),
      object: to_string(runner),
      path: nil,
      text: runner_text(event),
      tone: if(event in [:runner_disconnected, :runner_dropped], do: :warning, else: :signal),
      kind: event
    })
  end

  def runner(socket, _event, _data), do: socket

  @doc """
  Puts the attention items that appeared and cleared since the last read on
  the river.
  """
  def attention(socket, appeared, cleared) do
    now = DateTime.utc_now()

    socket =
      Enum.reduce(appeared, socket, fn item, socket ->
        push(socket, item.namespace, %{
          at: now,
          namespace: item.namespace,
          object: item.object.id,
          path: nil,
          text: "needs attention: " <> item.what,
          tone: item.severity,
          kind: :appeared
        })
      end)

    Enum.reduce(cleared, socket, fn item, socket ->
      push(socket, item.namespace, %{
        at: now,
        namespace: item.namespace,
        object: item.object.id,
        path: nil,
        text: "cleared: " <> item.what,
        tone: :positive,
        kind: :cleared
      })
    end)
  end

  # A namespace the token does not reach is never shown, and a namespace's
  # screen shows only its own. Only an attention item may name no namespace —
  # a parked relay class, the controller — and the pulse gathered those with
  # the operator's own token; a signal naming none is dropped before here.
  defp push(socket, namespace, event) do
    namespace = namespace && to_string(namespace)
    reachable = socket.assigns[:shell_namespaces] || []
    scope = socket.assigns[:scoped_namespace]

    if is_nil(namespace) or (namespace in reachable and scope in [nil, namespace]) do
      assign(socket, river: Enum.take([event | socket.assigns.river], @max))
    else
      socket
    end
  end

  @doc "What a lifecycle signal says happened."
  def lifecycle_text(%{event: :relay_started} = entry),
    do: "started from #{entry.factory || "an unnamed factory"}"

  def lifecycle_text(%{event: :relay_stopped} = entry), do: "stopped: #{reason(entry.reason)}"

  def lifecycle_text(%{event: :relay_exited} = entry),
    do: "exited on runner #{entry.runner || "—"}: #{reason(entry.reason)}"

  defp reason(nil), do: "no reason given"
  defp reason(reason), do: Format.printable(reason)

  defp runner_text(:runner_connected), do: "runner connected"
  defp runner_text(:runner_disconnected), do: "runner disconnected"
  defp runner_text(:runner_dropped), do: "runner dropped"
  defp runner_text(:runner_readmitted), do: "runner readmitted"

  # ---- Rendering ----

  @doc """
  The river: its 15-minute track and the events, newest first, each with its
  time, its object and a sentence. It says that it covers what this console
  saw since the screen opened.
  """
  attr :events, :list, required: true
  attr :error, :any, default: nil
  attr :now, :any, default: nil
  attr :testid, :string, default: "river"

  def river(assigns) do
    now = assigns.now || DateTime.utc_now()

    assigns =
      assign(assigns,
        now: now,
        marks:
          for(
            event <- assigns.events,
            age = DateTime.diff(now, event.at),
            age >= 0 and age <= @window_s,
            do: {event, Float.round(100 - age * 100 / @window_s, 2)}
          )
      )

    ~H"""
    <div class="fui-river" data-testid={@testid}>
      <div :if={@error} data-testid="lifecycle-error">
        <.runtime_error error={@error} action="the relay lifecycle feed" />
      </div>
      <div class="fui-river-track" aria-hidden="true">
        <span
          :for={{event, left} <- @marks}
          class="fui-river-mark"
          data-tone={event.tone}
          style={"left: #{left}%"}
        >
        </span>
      </div>
      <div class="fui-river-scale" aria-hidden="true">
        <span>15 min ago</span><span>now</span>
      </div>
      <p :if={@events == []} class="fui-figures" data-testid="river-empty">
        Nothing yet: relays starting and stopping, runners coming and going and problems
        appearing or clearing show here as this console sees them, from when this screen opened.
      </p>
      <ol :if={@events != []} class="fui-river-list" aria-label="Events, newest first">
        <li
          :for={{event, index} <- Enum.with_index(@events)}
          class="fui-river-event"
          data-testid={"lifecycle-entry-#{index}"}
        >
          <span class="fui-river-time">{Format.time_of_day(event.at)}</span>
          <span class="fui-river-object">
            <.link :if={event.path} navigate={event.path}>{event.object}</.link>
            <span :if={!event.path}>{event.object}</span>
          </span>
          <span data-testid={"lifecycle-what-#{index}"}>
            <span class="fui-tone-neutral">{event.namespace}</span> {event.text}
          </span>
        </li>
      </ol>
      <p :if={@events != []} class="fui-figures">
        What this console saw since the screen opened; at most the last fifty.
      </p>
    </div>
    """
  end
end
