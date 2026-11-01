defmodule FlezhaConsoleWeb.ListenLive do
  @moduledoc """
  A relay's outputs or inputs, as they happen.

  Each open screen holds its own listen: an `EventFeed` over
  `Relay.listen/5`, linked to the screen, so closing the screen or switching
  direction ends the listen on the controller.
  """

  use FlezhaConsoleWeb, :live_view

  alias FlezhaConsole.Format
  alias FlezhaConsole.Service.EventFeed
  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.RelayState

  @max_messages 200
  @record_kinds [:output, :input, :part, :dead_lettered]

  @impl true
  def mount(%{"ns" => ns, "id" => relay_id}, _session, socket) do
    socket =
      socket
      |> FlezhaConsoleWeb.Live.Refresh.assign_token()
      |> assign(
        ns: ns,
        relay_id: relay_id,
        direction: "output",
        feed: nil,
        status: :connecting,
        error: nil,
        reconnected?: false,
        messages: [],
        paused: false,
        filter: "",
        filter_regex: nil,
        filter_error: nil,
        page_title: "Listen: #{relay_id}",
        message_count: 0,
        partitions: [],
        serving: nil,
        factory_id: nil,
        relay_state: nil
      )

    # Read once, on the connected mount.
    socket = if connected?(socket), do: read_relay(socket), else: socket

    {:ok, if(connected?(socket), do: listen(socket), else: socket)}
  end

  # Its partitions, its state, and whether a runner serves its factory: a
  # relay none serves is offered a send, but not a call nobody could answer.
  defp read_relay(%{assigns: %{ns: ns, relay_id: relay_id, flezha_token: token}} = socket) do
    {_read, row, partitions} = NodeManager.relay_and_partitions(ns, relay_id, token)
    factory = row && row[:factory]

    assign(socket,
      partitions: partitions,
      serving: factory && NodeManager.serving_count(ns, factory, token),
      factory_id: factory,
      relay_state: row && RelayState.of(row, suspended?(ns, relay_id, token))
    )
  end

  # The relay's own suspended flag, which the registry's verdict can lag.
  defp suspended?(ns, relay_id, token) do
    case NodeManager.overwatch_facts(ns, relay_id, token) do
      {:ok, facts} -> facts.suspended
      _unread -> nil
    end
  end

  @impl true
  def terminate(_reason, socket) do
    EventFeed.stop(socket.assigns[:feed])
    :ok
  end

  @impl true
  def handle_event("switch_direction", %{"value" => direction}, socket)
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
    {:noreply, assign(socket, [filter: filter] ++ compile_filter(filter))}
  end

  @impl true
  def handle_info({:feed_event, :listen, :attached}, socket) do
    {:noreply, assign(socket, status: :connected)}
  end

  def handle_info({:feed_event, :listen, {kind, _, _}} = record, socket)
      when kind in @record_kinds do
    {:noreply, add(socket, queued([record]))}
  end

  def handle_info({:feed_event, :listen, _other}, socket), do: {:noreply, socket}

  def handle_info({:feed_error, :listen, error}, socket) do
    {:noreply, assign(socket, status: :error, error: error, feed: nil)}
  end

  # The controller cut the stream while this screen fell behind, and the feed
  # holds a new one: what was sent in between is not shown.
  def handle_info({:feed_reconnected, :listen}, socket),
    do: {:noreply, assign(socket, reconnected?: true)}

  # The listen answered, so the relay ended or the controller let it go.
  def handle_info({:feed_ended, :listen, _answer}, socket) do
    {:noreply, assign(socket, status: :ended, feed: nil)}
  end

  defp listen(socket) do
    # Stopped under its tag, so nothing the old listen sent reaches the new one.
    EventFeed.stop(socket.assigns.feed, :listen)
    %{ns: ns, relay_id: id, direction: direction, flezha_token: token} = socket.assigns
    feed = EventFeed.listen(ns, id, String.to_existing_atom(direction), token, :listen)
    assign(socket, feed: feed, status: :connecting, error: nil, reconnected?: false)
  end

  # Every record already waiting is taken in the same pass, newest first, so a
  # busy relay costs one render per pass instead of one per record, which would
  # fall behind and queue without bound.
  defp queued(records) do
    receive do
      {:feed_event, :listen, {kind, _, _}} = record when kind in @record_kinds ->
        queued([record | records])
    after
      0 -> records
    end
  end

  defp add(socket, records) do
    count = socket.assigns.message_count + length(records)

    if socket.assigns.paused do
      assign(socket, message_count: count)
    else
      frames = records |> Enum.take(@max_messages) |> Enum.map(&frame/1)
      messages = Enum.take(frames ++ socket.assigns.messages, @max_messages)
      assign(socket, messages: messages, message_count: count)
    end
  end

  defp frame({:feed_event, :listen, {:dead_lettered, error, meta}}) do
    frame = %{Format.frame("", meta) | message: NodeManager.error(error).message}
    Map.put(frame, :kind, :dead_lettered)
  end

  defp frame({:feed_event, :listen, {kind, payload, meta}}),
    do: Map.put(Format.frame(payload, meta), :kind, kind)

  # Compiled once per change, so an invalid pattern is reported once and a
  # valid one is not recompiled for every record that arrives.
  defp compile_filter(""), do: [filter_regex: nil, filter_error: nil]

  defp compile_filter(filter) do
    case Regex.compile(filter) do
      {:ok, regex} ->
        [filter_regex: regex, filter_error: nil]

      {:error, {reason, at}} ->
        [
          filter_regex: nil,
          filter_error: "Not a regular expression: #{reason} at #{at}. Showing everything."
        ]
    end
  end

  defp filtered_messages(messages, nil), do: messages

  defp filtered_messages(messages, regex),
    do: Enum.filter(messages, &Regex.match?(regex, &1.message))
end
