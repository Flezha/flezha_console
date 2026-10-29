defmodule FlezhaConsoleWeb.Live.Refresh do
  @moduledoc """
  Keeping a LiveView that projects controller state current.

  There are two ways such a screen goes stale and one mechanism for both: a
  periodic reload, and the runner lifecycle events the event feed forwards.
  Polling is the fallback that keeps a screen current when the feed cannot be
  established; the forwarded events are what make a runner connecting or
  disconnecting visible before the next tick. Holding both here means a new
  screen gets them by saying so, rather than by remembering to copy a timer and
  a subscription.

      use FlezhaConsoleWeb.Live.Refresh,
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

  A screen declaring `background: true` reads off its LiveView process instead,
  so a slow controller delays its figures but never a click. It implements
  `refresh_read/1`, which answers a function that makes the screen's calls from
  plain values (never the socket), and `refresh_apply/2`, which takes that
  function's `{:ok, answer}` or `{:exit, reason}` on the process. `refresh/1`
  is then generated: it starts a read the screen always shows, which is what an
  operator's action asks for. One read is in flight at a time; a tick due
  meanwhile is skipped and any request holds one read to follow it. An answer
  arriving while a tick would be held is dropped, unless it is the screen's
  first or one `refresh/1` asked for.

  Arming also states the screen's liveness: `:refresh_interval`, `:refresh_at`
  and `:refresh_paused` are what the shell renders `liveness/1` from, so a
  screen says it refreshes by refreshing rather than by remembering to say so.
  """

  require Phoenix.LiveView

  @callback refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  @callback refresh_read(Phoenix.LiveView.Socket.t()) :: (-> term())
  @callback refresh_apply(Phoenix.LiveView.Socket.t(), {:ok, term()} | {:exit, term()}) ::
              Phoenix.LiveView.Socket.t()
  @callback refresh_paused?(Phoenix.LiveView.Socket.t()) :: boolean()
  @callback refresh_hidden(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  @optional_callbacks refresh_read: 1, refresh_apply: 2

  @doc false
  # The operator's pause is read here rather than in the default
  # `refresh_paused?/1`, so a screen that overrides that callback to hold still
  # for its own modal cannot drop the operator's pause by forgetting to call
  # back into it.
  # `cause` is `:timer` for the periodic tick, `:action` for the read an
  # operator's action asks for, and `:request` for everything else. Only a
  # background screen tells them apart: there an action reads even when held.
  def tick(module, socket, cause \\ :request) do
    background? = module.__refresh_background__()

    cond do
      background? and cause == :action -> read(module, socket, cause)
      held?(module, socket) -> socket
      background? -> read(module, socket, cause)
      true -> socket |> module.refresh() |> mark_refreshed()
    end
  end

  defp held?(module, socket) do
    socket.assigns[:refresh_paused] || socket.assigns[:refresh_hidden] ||
      module.refresh_paused?(socket)
  end

  # A background screen's read. An `:action` read's answer is shown even on a
  # held screen.
  defp read(module, socket, cause) do
    cond do
      !socket.assigns[:refresh_reading] ->
        socket
        |> Phoenix.Component.assign(:refresh_forced, cause == :action)
        |> start_once(:refresh_reading, :refresh, module.refresh_read(socket))

      cause == :timer ->
        socket

      true ->
        again = if socket.assigns[:refresh_again] == :action, do: :action, else: cause
        Phoenix.Component.assign(socket, :refresh_again, again)
    end
  end

  @doc false
  # A background screen's answer: shown or dropped, then the read it held, if
  # any, starts.
  def answered(module, socket, result) do
    %{refresh_forced: forced, refresh_again: again} = socket.assigns
    socket = Phoenix.Component.assign(socket, :refresh_again, nil)

    socket =
      if forced or not socket.assigns.refresh_loaded or not held?(module, socket),
        do:
          socket
          |> module.refresh_apply(result)
          |> Phoenix.Component.assign(
            :refresh_loaded,
            socket.assigns.refresh_loaded or match?({:ok, _answer}, result)
          )
          |> mark_refreshed(),
        else: socket

    if again, do: tick(module, socket, again), else: socket
  end

  @doc """
  Starts `fun` as the async task `name` unless the one before it is still in
  flight, as the boolean assign `flag` says; `on_answer/4` clears `flag`.
  A read left to finish is never cancelled by a second, so an operator asking
  twice still sees an answer.
  """
  def start_once(socket, flag, name, fun) do
    if socket.assigns[flag],
      do: socket,
      else:
        socket |> Phoenix.Component.assign(flag, true) |> Phoenix.LiveView.start_async(name, fun)
  end

  @doc """
  Hands the answer of the task `start_once/4` started as `name` to
  `fun.(socket, result)`, with `flag` cleared, and passes every other task's
  answer on to the screen.
  """
  def on_answer(socket, name, flag, fun) do
    Phoenix.LiveView.attach_hook(socket, {:answer, name}, :handle_async, fn
      ^name, result, socket ->
        {:halt, socket |> Phoenix.Component.assign(flag, false) |> fun.(result)}

      _other, _result, socket ->
        {:cont, socket}
    end)
  end

  @doc """
  The interval a screen declaring `declared` refreshes at: `:refresh_interval_ms`
  when it is configured, which runs every screen at one cadence, else its own.
  """
  def interval(declared),
    do: Application.get_env(:flezha_console, :refresh_interval_ms, declared)

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
  A hook reports the tab's visibility as `"refresh_visibility"`. A screen
  holding a read open between ticks lets it go in `refresh_hidden/1`.
  """
  def visibility(socket, module, hidden) do
    was_hidden = socket.assigns[:refresh_hidden] || false
    socket = Phoenix.Component.assign(socket, :refresh_hidden, hidden)

    cond do
      was_hidden and not hidden -> tick(module, socket)
      hidden and not was_hidden -> module.refresh_hidden(socket)
      true -> socket
    end
  end

  @doc """
  Asks for a read soon rather than now. Requests made within
  `:refresh_coalesce_ms` (300 ms unless configured) are answered by one read,
  so a burst of events costs one; a window of `0` reads at once.
  """
  def request_tick(module, socket) do
    window = Application.get_env(:flezha_console, :refresh_coalesce_ms, 300)

    cond do
      window == 0 ->
        tick(module, socket)

      socket.assigns[:tick_requested] ->
        socket

      true ->
        Process.send_after(self(), :refresh_requested, window)
        Phoenix.Component.assign(socket, :tick_requested, true)
    end
  end

  @doc false
  # A runner of the screen's namespace came or went: what was read once and
  # kept, such as a relay's announced graph, may be stale, so `:runner_epoch`
  # counts these for whoever keys a cache on it, and the screen reads soon.
  def runner_changed(module, socket) do
    epoch = (socket.assigns[:runner_epoch] || 0) + 1
    request_tick(module, Phoenix.Component.assign(socket, :runner_epoch, epoch))
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
      FlezhaConsole.Accounts.Scope.flezha_token(socket.assigns[:current_scope])
    end)
    |> Phoenix.Component.assign_new(:operations, fn %{flezha_token: token} ->
      FlezhaConsole.Service.NodeManager.operations(token)
    end)
  end

  defmacro __using__(opts) do
    interval = Keyword.fetch!(opts, :every)
    events = Keyword.get(opts, :on_events, [])
    background = Keyword.get(opts, :background, false)

    background_read =
      if background do
        quote do
          @impl FlezhaConsoleWeb.Live.Refresh
          def refresh(socket), do: FlezhaConsoleWeb.Live.Refresh.tick(__MODULE__, socket, :action)

          @doc """
          This screen's read made once on its own process, for a first load
          the screen opens on: every tick after it reads off the process.
          """
          def read_now(socket) do
            socket
            |> refresh_apply({:ok, refresh_read(socket).()})
            |> Phoenix.Component.assign(:refresh_loaded, true)
            |> FlezhaConsoleWeb.Live.Refresh.mark_refreshed()
          end

          @doc """
          The read a change of the screen's address asks for, on a connected
          socket: the first made at once, so the screen opens on its figures,
          and every later one in the background, so a slow controller never
          holds a filter or a click.
          """
          def read_when_connected(socket) do
            cond do
              not Phoenix.LiveView.connected?(socket) -> socket
              socket.assigns[:refresh_loaded] -> refresh(socket)
              true -> read_now(socket)
            end
          end
        end
      end

    forwarded =
      if events != [] do
        quote do
          def handle_info({:flezha_event, event, data}, socket)
              when event in @refresh_events do
            # The palette's relay index goes stale on exactly these events,
            # and this is the only place the console hears them.
            socket =
              socket
              |> FlezhaConsoleWeb.CommandPalette.invalidate()
              |> FlezhaConsoleWeb.River.runner(event, data)

            if FlezhaConsoleWeb.Live.Refresh.concerns?(socket, data),
              do: {:noreply, FlezhaConsoleWeb.Live.Refresh.runner_changed(__MODULE__, socket)},
              else: {:noreply, socket}
          end
        end
      end

    quote do
      @behaviour FlezhaConsoleWeb.Live.Refresh

      @refresh_interval unquote(interval)
      @refresh_events unquote(events)

      @doc false
      def __refresh_background__, do: unquote(background)

      @doc false
      def schedule_refresh,
        do:
          Process.send_after(
            self(),
            :refresh,
            FlezhaConsoleWeb.Live.Refresh.interval(@refresh_interval)
          )

      @doc """
      Arms the tick and, when this screen listens for them, the forwarded events.

      Does nothing on the dead render: there is no process there to deliver to.
      """
      def start_refresh(socket) do
        socket =
          socket
          |> FlezhaConsoleWeb.Live.Refresh.assign_token()
          |> Phoenix.Component.assign(
            refresh_interval: FlezhaConsoleWeb.Live.Refresh.interval(@refresh_interval),
            refresh_paused: false
          )

        # A plain screen's first load follows arming at once, so this is when
        # what is on screen was read; a background screen's is when it answers.
        socket =
          if unquote(background),
            do: socket,
            else: FlezhaConsoleWeb.Live.Refresh.mark_refreshed(socket)

        if Phoenix.LiveView.connected?(socket) do
          if @refresh_events != [] do
            Phoenix.PubSub.subscribe(
              FlezhaConsole.PubSub,
              FlezhaConsole.Service.EventFeed.topic()
            )
          end

          schedule_refresh()
        end

        if unquote(background) and Phoenix.LiveView.connected?(socket) do
          socket
          |> Phoenix.Component.assign(
            refresh_forced: false,
            refresh_again: nil,
            refresh_loaded: false
          )
          |> FlezhaConsoleWeb.Live.Refresh.on_answer(
            :refresh,
            :refresh_reading,
            &FlezhaConsoleWeb.Live.Refresh.answered(__MODULE__, &1, &2)
          )
        else
          socket
        end
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
        {:noreply, FlezhaConsoleWeb.Live.Refresh.tick(__MODULE__, socket, :timer)}
      end

      def handle_info(:refresh_requested, socket) do
        socket = Phoenix.Component.assign(socket, :tick_requested, false)
        {:noreply, FlezhaConsoleWeb.Live.Refresh.tick(__MODULE__, socket)}
      end

      unquote(forwarded)

      unquote(background_read)

      @impl Phoenix.LiveView
      def handle_event("refresh_toggle", _params, socket) do
        {:noreply, FlezhaConsoleWeb.Live.Refresh.toggle_pause(socket, __MODULE__)}
      end

      def handle_event("refresh_visibility", %{"hidden" => hidden}, socket)
          when is_boolean(hidden) do
        {:noreply, FlezhaConsoleWeb.Live.Refresh.visibility(socket, __MODULE__, hidden)}
      end

      @impl FlezhaConsoleWeb.Live.Refresh
      def refresh_paused?(_socket), do: false

      @impl FlezhaConsoleWeb.Live.Refresh
      def refresh_hidden(socket), do: socket

      defoverridable refresh_paused?: 1, refresh_hidden: 1
    end
  end
end
