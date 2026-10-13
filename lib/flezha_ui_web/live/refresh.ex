defmodule FlezhaUiWeb.Live.Refresh do
  @moduledoc """
  Keeping a LiveView that projects controller state current.

  There are two ways such a screen goes stale and one mechanism for both: a
  periodic reload, and the runner lifecycle events the event feed forwards.
  Polling is the fallback that keeps a screen current when the feed cannot be
  established; the forwarded events are what make a runner connecting or
  disconnecting visible before the next tick. Holding both here means a new
  screen gets them by saying so, rather than by remembering to copy a timer and
  a subscription.

      use FlezhaUiWeb.Live.Refresh,
        every: 5_000,
        on_events: [:runner_connected, :runner_disconnected]

      def mount(_params, _session, socket) do
        {:ok, socket |> start_refresh() |> refresh()}
      end

      @impl true
      def refresh(socket), do: load(socket)

  The using module implements `refresh/1` and arms the screen with
  `start_refresh/1`. It may also override `refresh_paused?/1` to skip a tick —
  screens with an open modal do, so a row cannot move under the operator
  between reading it and confirming.

  Arming also states the screen's liveness: `:refresh_interval`, `:refresh_at`
  and `:refresh_paused` are what the shell renders `liveness/1` from, so a
  screen says it refreshes by refreshing rather than by remembering to say so.
  """

  @callback refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  @callback refresh_paused?(Phoenix.LiveView.Socket.t()) :: boolean()

  @doc false
  # The operator's pause is read here rather than in the default
  # `refresh_paused?/1`, so a screen that overrides that callback to hold still
  # for its own modal cannot drop the operator's pause by forgetting to call
  # back into it.
  def tick(module, socket) do
    if socket.assigns[:refresh_paused] || socket.assigns[:refresh_hidden] ||
         module.refresh_paused?(socket) do
      socket
    else
      socket |> module.refresh() |> mark_refreshed()
    end
  end

  @doc false
  def mark_refreshed(socket) do
    Phoenix.Component.assign(socket, :refresh_at, DateTime.utc_now())
  end

  @doc """
  Holds the screen still, or picks it back up.

  Resuming refreshes at once rather than leaving the operator on stale rows
  until the next tick. The timer itself is never cancelled — it reschedules
  unconditionally — so nothing has to re-arm it.
  """
  def toggle_pause(socket, module) do
    paused = not (socket.assigns[:refresh_paused] || false)
    socket = Phoenix.Component.assign(socket, :refresh_paused, paused)

    if paused, do: socket, else: tick(module, socket)
  end

  @doc """
  Stops reading while the browser tab is hidden, and reads at once when it is
  shown again, so a tab left in the background asks the controller nothing.
  A hook reports the tab's visibility as `"refresh_visibility"`.
  """
  def visibility(socket, module, hidden) do
    was_hidden = socket.assigns[:refresh_hidden] || false
    socket = Phoenix.Component.assign(socket, :refresh_hidden, hidden)

    if was_hidden and not hidden, do: tick(module, socket), else: socket
  end

  @doc false
  # A runner of the screen's namespace came or went: what was read once and
  # kept, such as a relay's announced graph, may be stale, so `:runner_epoch`
  # counts these for whoever keys a cache on it, and the screen reads at once.
  def runner_changed(module, socket) do
    epoch = (socket.assigns[:runner_epoch] || 0) + 1
    tick(module, Phoenix.Component.assign(socket, :runner_epoch, epoch))
  end

  @doc false
  # A screen scoped to one namespace has nothing to reload when a runner of
  # another comes or goes; a fleet reconnecting would otherwise reload every
  # open screen once per runner.
  def concerns?(%{assigns: %{ns: ns}}, {event_ns, _runner})
      when is_binary(ns) and is_binary(event_ns),
      do: ns == event_ns

  def concerns?(_socket, _data), do: true

  @doc """
  Puts the caller's flezha token on the socket, once, with the operations its
  role is granted (`NodeManager.operations/1`), which decide the controls a
  screen renders through `NodeManager.granted?/2`.

  Every authorized controller call needs the token, and resolving it per call
  would re-read the user's stored credential on every panel of every tick. Held
  as an assign so a screen threads a value it already has.
  """
  def assign_token(socket) do
    socket
    |> Phoenix.Component.assign_new(:flezha_token, fn ->
      FlezhaUi.Accounts.Scope.flezha_token(socket.assigns[:current_scope])
    end)
    |> Phoenix.Component.assign_new(:operations, fn %{flezha_token: token} ->
      FlezhaUi.Service.NodeManager.operations(token)
    end)
  end

  defmacro __using__(opts) do
    interval = Keyword.fetch!(opts, :every)
    events = Keyword.get(opts, :on_events, [])

    forwarded =
      if events != [] do
        quote do
          def handle_info({:flezha_event, event, data}, socket)
              when event in @refresh_events do
            # The palette's relay index goes stale on exactly these events,
            # and this is the only place the console hears them.
            socket =
              socket
              |> FlezhaUiWeb.CommandPalette.invalidate()
              |> FlezhaUiWeb.River.runner(event, data)

            if FlezhaUiWeb.Live.Refresh.concerns?(socket, data),
              do: {:noreply, FlezhaUiWeb.Live.Refresh.runner_changed(__MODULE__, socket)},
              else: {:noreply, socket}
          end
        end
      end

    quote do
      @behaviour FlezhaUiWeb.Live.Refresh

      @refresh_interval unquote(interval)
      @refresh_events unquote(events)

      @doc false
      def schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)

      @doc """
      Arms the tick and, when this screen listens for them, the forwarded events.

      Does nothing on the dead render: there is no process there to deliver to.
      """
      def start_refresh(socket) do
        socket =
          socket
          |> FlezhaUiWeb.Live.Refresh.assign_token()
          |> Phoenix.Component.assign(
            refresh_interval: @refresh_interval,
            refresh_paused: false
          )
          # Arming is immediately followed by the screen's own first load, so
          # this is when what is on screen was read.
          |> FlezhaUiWeb.Live.Refresh.mark_refreshed()

        if Phoenix.LiveView.connected?(socket) do
          if @refresh_events != [] do
            Phoenix.PubSub.subscribe(FlezhaUi.PubSub, FlezhaUi.Service.EventFeed.topic())
          end

          schedule_refresh()
        end

        socket
      end

      @doc """
      `refresh/1` on a connected socket only, for a screen's first read: the
      dead render shows the screen's skeleton rather than a read the connected
      mount repeats at once.
      """
      def refresh_when_connected(socket) do
        if Phoenix.LiveView.connected?(socket), do: refresh(socket), else: socket
      end

      @impl Phoenix.LiveView
      def handle_info(:refresh, socket) do
        # Rescheduled unconditionally, so a paused screen resumes on its own
        # rather than needing whatever unpaused it to restart the timer.
        schedule_refresh()
        {:noreply, FlezhaUiWeb.Live.Refresh.tick(__MODULE__, socket)}
      end

      unquote(forwarded)

      @impl Phoenix.LiveView
      def handle_event("refresh_toggle", _params, socket) do
        {:noreply, FlezhaUiWeb.Live.Refresh.toggle_pause(socket, __MODULE__)}
      end

      def handle_event("refresh_visibility", %{"hidden" => hidden}, socket)
          when is_boolean(hidden) do
        {:noreply, FlezhaUiWeb.Live.Refresh.visibility(socket, __MODULE__, hidden)}
      end

      @impl FlezhaUiWeb.Live.Refresh
      def refresh_paused?(_socket), do: false

      defoverridable refresh_paused?: 1
    end
  end
end
