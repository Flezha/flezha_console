defmodule FlezhaUiWeb.Live.Refresh do
  @moduledoc """
  Keeping a LiveView that projects controller state current.

  There are two ways such a screen goes stale and one mechanism for both: a
  periodic reload, and the lifecycle events the controller relays. Polling is
  the fallback that keeps a screen current when the event relay cannot be
  established; the relayed events are what make a runner connecting or
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
  """

  @callback refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  @callback refresh_paused?(Phoenix.LiveView.Socket.t()) :: boolean()

  @doc false
  def tick(module, socket) do
    if module.refresh_paused?(socket), do: socket, else: module.refresh(socket)
  end

  defmacro __using__(opts) do
    interval = Keyword.fetch!(opts, :every)
    events = Keyword.get(opts, :on_events, [])

    relayed =
      if events != [] do
        quote do
          def handle_info({:flezha_event, event, _data}, socket)
              when event in @refresh_events do
            {:noreply, FlezhaUiWeb.Live.Refresh.tick(__MODULE__, socket)}
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
      Arms the tick and, when this screen listens for them, the relayed events.

      Does nothing on the dead render: there is no process there to deliver to.
      """
      def start_refresh(socket) do
        if Phoenix.LiveView.connected?(socket) do
          if @refresh_events != [] do
            Phoenix.PubSub.subscribe(FlezhaUi.PubSub, FlezhaUi.Service.EventBridge.topic())
          end

          schedule_refresh()
        end

        socket
      end

      @impl Phoenix.LiveView
      def handle_info(:refresh, socket) do
        # Rescheduled unconditionally, so a paused screen resumes on its own
        # rather than needing whatever unpaused it to restart the timer.
        schedule_refresh()
        {:noreply, FlezhaUiWeb.Live.Refresh.tick(__MODULE__, socket)}
      end

      unquote(relayed)

      @impl FlezhaUiWeb.Live.Refresh
      def refresh_paused?(_socket), do: false

      defoverridable refresh_paused?: 1
    end
  end
end
