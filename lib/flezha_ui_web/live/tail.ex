defmodule FlezhaUiWeb.Live.Tail do
  @moduledoc """
  A live tail carried by `FlezhaUi.Service.EventFeed`.

  Two screens tail something — the audit log and an observability source — and
  the plumbing either would need is identical: open the published tail through
  a feed linked to the screen, prepend what arrives to a bounded list, say so
  when the tail is refused or re-established, and stop the feed on the way out.
  Only the opening call and the envelope differ.

  So it is written once, the way `FlezhaUiWeb.Live.Refresh` is:

      use FlezhaUiWeb.Live.Tail, tag: :audit_tail, max: 200

      def unwrap_tail(record), do: record

  The using module calls `start_tail/3` with a function opening the tail for an
  emit pid — one of the `NodeManager` stream functions — and reads
  `@tail_records`, `@tailing`, `@tail_error` and `@tail_reconnected?` from the
  socket. Stopping the feed releases the controller's subscription; there is
  no separate unsubscribe.
  """

  @doc "The record a forwarded event carries, unwrapped from its envelope."
  @callback unwrap_tail(term()) :: term()

  defmacro __using__(opts) do
    tag = Keyword.fetch!(opts, :tag)
    max = Keyword.get(opts, :max, 200)

    quote do
      @behaviour FlezhaUiWeb.Live.Tail

      @tail_tag unquote(tag)
      @tail_max unquote(max)

      @doc false
      def init_tail(socket) do
        Phoenix.Component.assign(socket,
          tailing: nil,
          tail_feed: nil,
          tail_error: nil,
          tail_records: [],
          tail_reconnected?: false
        )
      end

      @doc """
      Opens a tail with `open`, a function of the emit pid, replacing any tail
      already running. `label` is what the screen calls what it is tailing.
      """
      def start_tail(socket, open, label \\ true) do
        socket = stop_tail(socket)

        {:ok, feed} =
          FlezhaUi.Service.EventFeed.start_link(
            open: open,
            to: {:send, self(), @tail_tag},
            retry: true
          )

        Phoenix.Component.assign(socket,
          tailing: label,
          tail_feed: feed,
          tail_records: [],
          tail_error: nil,
          tail_reconnected?: false
        )
      end

      @doc "Stops the running tail, if there is one. Safe to call unconditionally."
      def stop_tail(socket) do
        FlezhaUi.Service.EventFeed.stop(socket.assigns[:tail_feed])
        Phoenix.Component.assign(socket, tailing: nil, tail_feed: nil)
      end

      @impl Phoenix.LiveView
      def handle_info({:feed_event, @tail_tag, event}, socket) do
        records = Enum.take([unwrap_tail(event) | socket.assigns.tail_records], @tail_max)

        {:noreply, Phoenix.Component.assign(socket, tail_records: records)}
      end

      # Refused or cut off — a disabled pubsub sink, an unbound principal, a
      # lost controller. Reported, because a tail that is not running is
      # indistinguishable on screen from one that is merely quiet. The feed
      # keeps retrying, so the error clears when the tail comes back.
      def handle_info({:feed_error, @tail_tag, reason}, socket) do
        {:noreply, Phoenix.Component.assign(socket, tail_error: reason)}
      end

      def handle_info({:feed_ended, @tail_tag, _answer}, socket), do: {:noreply, socket}

      # A tail that silently resumed has a hole in it the operator cannot see.
      def handle_info({:feed_reconnected, @tail_tag}, socket) do
        {:noreply, Phoenix.Component.assign(socket, tail_error: nil, tail_reconnected?: true)}
      end

      @impl Phoenix.LiveView
      def terminate(_reason, socket) do
        stop_tail(socket)
        :ok
      end

      defoverridable terminate: 2
    end
  end
end
