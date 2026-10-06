defmodule FlezhaUiWeb.ListenLive do
  @moduledoc """
  A relay's outputs or inputs, as they happen.

  Each open screen holds its own listen: an `EventFeed` over
  `Relay.listen/5`, linked to the screen, so closing the screen or switching
  direction ends the listen on the controller.
  """

  use FlezhaUiWeb, :live_view

  alias FlezhaUi.Format
  alias FlezhaUi.Service.EventFeed
  alias FlezhaUi.Service.NodeManager

  @max_messages 200

  @impl true
  def mount(%{"ns" => ns, "id" => relay_id}, _session, socket) do
    socket =
      socket
      |> FlezhaUiWeb.Live.Refresh.assign_token()
      |> assign(
        ns: ns,
        relay_id: relay_id,
        direction: "output",
        feed: nil,
        tag: nil,
        status: :connecting,
        error: nil,
        messages: [],
        paused: false,
        filter: "",
        page_title: "Listen: #{relay_id}",
        message_count: 0
      )

    {:ok, if(connected?(socket), do: listen(socket), else: socket)}
  end

  @impl true
  def terminate(_reason, socket) do
    EventFeed.stop(socket.assigns[:feed])
    :ok
  end

  @impl true
  def handle_event("switch_direction", %{"direction" => direction}, socket)
      when direction in ~w(input output) do
    {:noreply, socket |> assign(direction: direction, messages: [], message_count: 0) |> listen()}
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, paused: !socket.assigns.paused)}
  end

  @impl true
  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, messages: [], message_count: 0)}
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, filter: filter)}
  end

  @impl true
  # Matched on the current listen's tag: a feed stopped by a direction switch
  # may still have a message in flight.
  def handle_info({_kind, tag, _payload}, %{assigns: %{tag: current}} = socket)
      when tag != current,
      do: {:noreply, socket}

  def handle_info({:feed_event, _tag, :attached}, socket) do
    {:noreply, assign(socket, status: :connected)}
  end

  def handle_info({:feed_event, _tag, {kind, payload, meta}}, socket)
      when kind in [:output, :input, :part] do
    {:noreply, add(socket, Map.put(Format.frame(payload, meta), :kind, kind))}
  end

  def handle_info({:feed_event, _tag, {:dead_lettered, error, meta}}, socket) do
    frame = %{Format.frame("", meta) | message: NodeManager.error(error).message}
    {:noreply, add(socket, Map.put(frame, :kind, :dead_lettered))}
  end

  def handle_info({:feed_event, _tag, _other}, socket), do: {:noreply, socket}

  def handle_info({:feed_error, _tag, error}, socket) do
    {:noreply, assign(socket, status: :error, error: error, feed: nil)}
  end

  # The listen answered, so the relay ended or the controller let it go.
  def handle_info({:feed_ended, _tag, _answer}, socket) do
    {:noreply, assign(socket, status: :ended, feed: nil)}
  end

  defp listen(socket) do
    EventFeed.stop(socket.assigns.feed)
    %{ns: ns, relay_id: id, direction: direction, flezha_token: token} = socket.assigns
    direction = String.to_existing_atom(direction)

    tag = make_ref()

    {:ok, feed} =
      EventFeed.start_link(
        open: &NodeManager.listen(ns, id, direction, token, &1),
        to: {:send, self(), tag}
      )

    assign(socket, feed: feed, tag: tag, status: :connecting, error: nil)
  end

  defp add(socket, frame) do
    count = socket.assigns.message_count + 1

    if socket.assigns.paused do
      assign(socket, message_count: count)
    else
      messages = Enum.take([frame | socket.assigns.messages], @max_messages)
      assign(socket, messages: messages, message_count: count)
    end
  end

  defp filtered_messages(messages, ""), do: messages

  defp filtered_messages(messages, filter) do
    case Regex.compile(filter) do
      {:ok, regex} -> Enum.filter(messages, &Regex.match?(regex, &1.message))
      _ -> messages
    end
  end
end
