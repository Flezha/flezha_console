defmodule FlezhaUiWeb.Live.Refresh do
  @moduledoc """
  Periodic reload for a LiveView that projects controller state.

  Every screen here polls, and polling is not just convenience: it is the
  fallback that keeps a screen current when the controller event relay cannot
  be established. Holding that guarantee in one place means a new screen gets
  it by saying so, rather than by remembering to copy a timer.

      use FlezhaUiWeb.Live.Refresh, every: 5_000

      @impl true
      def refresh(socket), do: load(socket)

  The using module implements `refresh/1`. It may also override
  `refresh_paused?/1` to skip a tick — screens with an open modal do, so a row
  cannot move under the operator between reading it and confirming.
  """

  @callback refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  @callback refresh_paused?(Phoenix.LiveView.Socket.t()) :: boolean()

  @doc false
  def tick(module, socket) do
    if module.refresh_paused?(socket), do: socket, else: module.refresh(socket)
  end

  defmacro __using__(opts) do
    interval = Keyword.fetch!(opts, :every)

    quote do
      @behaviour FlezhaUiWeb.Live.Refresh

      @refresh_interval unquote(interval)

      @doc false
      def schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)

      @impl Phoenix.LiveView
      def handle_info(:refresh, socket) do
        # Rescheduled unconditionally, so a paused screen resumes on its own
        # rather than needing whatever unpaused it to restart the timer.
        schedule_refresh()
        {:noreply, FlezhaUiWeb.Live.Refresh.tick(__MODULE__, socket)}
      end

      @impl FlezhaUiWeb.Live.Refresh
      def refresh_paused?(_socket), do: false

      defoverridable refresh_paused?: 1
    end
  end
end
