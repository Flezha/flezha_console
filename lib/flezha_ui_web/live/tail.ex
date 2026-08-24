defmodule FlezhaUiWeb.Live.Tail do
  @moduledoc """
  A live tail carried by the controller-resident relay.

  Two screens tail something — the audit log and an observability source — and
  the plumbing either would need is identical: start a relay on the controller,
  hold its pid, prepend what arrives to a bounded list, say so when the
  subscription is refused or re-established, and stop it on the way out. Only
  the subscription tuple and the envelope differ.

  So it is written once, the way `FlezhaUiWeb.Live.Refresh` is:

      use FlezhaUiWeb.Live.Tail, tag: :audit_tail, max: 200

      def unwrap_tail({:audit_record, _ref, record}), do: record
      def unwrap_tail(other), do: other

  The using module calls `start_tail/2` with its subscription and reads
  `@tail_records`, `@tailing`, `@tail_error` and `@tail_reconnected?` from the
  socket. It must not build a second subscription mechanism: every tail rides
  `FlezhaUi.Service.EventRelay`, because the controller's tail APIs register the
  *calling* process and an `:erpc` call's process does not outlive the call.
  """

  @doc "The record a relayed message carries, unwrapped from its envelope."
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
          tail_relay: nil,
          tail_error: nil,
          tail_records: [],
          tail_reconnected?: false
        )
      end

      @doc """
      Starts `subscription` on the controller, replacing any tail already
      running. `label` is what the screen calls what it is tailing.
      """
      def start_tail(socket, subscription, label \\ true) do
        socket = stop_tail(socket)

        case FlezhaUi.Service.NodeManager.connected_node() do
          nil ->
            Phoenix.Component.assign(socket, tail_error: :node_not_connected)

          node ->
            relay =
              FlezhaUi.Service.EventBridge.start_relay(
                node,
                FlezhaUi.Service.EventBridge.relay_source(),
                self(),
                [subscription, @tail_tag]
              )

            case relay do
              {:ok, pid} ->
                Phoenix.Component.assign(socket,
                  tailing: label,
                  tail_relay: pid,
                  tail_records: [],
                  tail_error: nil,
                  tail_reconnected?: false
                )

              {:error, reason} ->
                Phoenix.Component.assign(socket, tail_error: reason)
            end
        end
      end

      @doc "Stops the running tail, if there is one. Safe to call unconditionally."
      def stop_tail(socket) do
        FlezhaUi.Service.EventBridge.stop_relay(socket.assigns[:tail_relay])
        Phoenix.Component.assign(socket, tailing: nil, tail_relay: nil)
      end

      @impl Phoenix.LiveView
      def handle_info({:relay_event, @tail_tag, message}, socket) do
        records = Enum.take([unwrap_tail(message) | socket.assigns.tail_records], @tail_max)

        {:noreply, Phoenix.Component.assign(socket, tail_records: records)}
      end

      # The controller refused the subscription — a disabled pubsub sink, an
      # unbound principal. Reported, because a tail that never started is
      # indistinguishable on screen from one that is merely quiet.
      def handle_info({:relay_error, @tail_tag, reason}, socket) do
        {:noreply,
         Phoenix.Component.assign(socket, tailing: nil, tail_relay: nil, tail_error: reason)}
      end

      # The bridge re-established a relay whose process died. Saying so matters:
      # a tail that silently resumed has a hole in it the operator cannot see.
      def handle_info({:relay_reconnected, _relay}, socket) do
        {:noreply, Phoenix.Component.assign(socket, tail_reconnected?: true)}
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
