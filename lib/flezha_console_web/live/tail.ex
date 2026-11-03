defmodule FlezhaConsoleWeb.Live.Tail do
  @moduledoc """
  A live tail carried by `FlezhaConsole.Service.EventFeed`.

  Several screens tail something — a log, an observability source, a relay's
  own history — and the plumbing each would need is identical: open the
  published tail through a feed linked to the screen, prepend what arrives to a
  bounded list, say so when the tail is refused or re-established, and stop the
  feed on the way out. Only the opening call and the envelope differ; a tail
  narrowed by filters carries them in the opening call.

  So it is written once, the way `FlezhaConsoleWeb.Live.Refresh` is:

      use FlezhaConsoleWeb.Live.Tail, tag: :logs_tail, max: 200

      def unwrap_tail(record), do: record

  The using module calls `start_tail/3` with a function opening the tail for an
  emit pid — one of the `NodeManager` stream functions — and reads
  `@tail_records`, `@tailing`, `@tail_error` and `@tail_reconnected?` from the
  socket. Stopping the feed releases the controller's subscription; there is
  no separate unsubscribe.
  """

  @doc "The record a forwarded event carries, unwrapped from its envelope."
  @callback unwrap_tail(term()) :: term()

  @doc false
  # `newest` and the `tag` records already in the mailbox, up to `max`, newest first.
  def waiting(newest, _tag, max) when length(newest) >= max, do: newest

  def waiting(newest, tag, max) do
    receive do
      {:feed_event, ^tag, event} -> waiting([event | newest], tag, max)
    after
      0 -> newest
    end
  end

  defmacro __using__(opts) do
    tag = Keyword.fetch!(opts, :tag)
    max = Keyword.get(opts, :max, 200)

    quote do
      @behaviour FlezhaConsoleWeb.Live.Tail

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
      already running. `label` is what the screen calls what it is tailing;
      `seed:` is what to show before the first live record, newest first.
      """
      def start_tail(socket, open, label \\ true, opts \\ []) do
        socket = stop_tail(socket)

        {:ok, feed} =
          FlezhaConsole.Service.EventFeed.start_link(
            open: open,
            to: {:send, self(), @tail_tag},
            retry: true
          )

        Phoenix.Component.assign(socket,
          tailing: label,
          tail_feed: feed,
          tail_records: Enum.take(Keyword.get(opts, :seed, []), @tail_max),
          tail_error: nil,
          tail_reconnected?: false
        )
      end

      @doc """
      Stops the running tail, if there is one, and drops what it already sent.
      Safe to call unconditionally.
      """
      def stop_tail(socket) do
        FlezhaConsole.Service.EventFeed.stop(socket.assigns[:tail_feed], @tail_tag)
        Phoenix.Component.assign(socket, tailing: nil, tail_feed: nil, tail_error: nil)
      end

      # Every record already waiting is taken with this one, so a busy tail —
      # a chatty source on every controller — renders once per batch and an
      # operator's click is never queued behind a backlog of renders.
      @impl Phoenix.LiveView
      def handle_info({:feed_event, @tail_tag, event}, socket) do
        records =
          [event]
          |> FlezhaConsoleWeb.Live.Tail.waiting(@tail_tag, @tail_max)
          |> Enum.map(&unwrap_tail/1)
          |> Enum.concat(socket.assigns.tail_records)
          |> Enum.take(@tail_max)

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
