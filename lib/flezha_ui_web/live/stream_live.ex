defmodule FlezhaUiWeb.StreamLive do
  use FlezhaUiWeb, :live_view

  alias FlezhaUi.Service.StreamBridge

  @max_messages 200

  @impl true
  def mount(%{"ns" => ns, "id" => operative_id} = _params, _session, socket) do
    io_type = "output"

    if connected?(socket) do
      StreamBridge.subscribe(ns, operative_id, io_type)
    end

    {:ok,
     assign(socket,
       ns: ns,
       operative_id: operative_id,
       io_type: io_type,
       status: :connecting,
       messages: [],
       paused: false,
       filter: "",
       page_title: "Stream: #{operative_id}",
       message_count: 0
     )}
  end

  @impl true
  def terminate(_reason, socket) do
    if connected?(socket) do
      StreamBridge.unsubscribe(
        socket.assigns.ns,
        socket.assigns.operative_id,
        socket.assigns.io_type
      )
    end

    :ok
  end

  @impl true
  def handle_event("switch_io", %{"type" => new_type}, socket) do
    %{ns: ns, operative_id: operative_id, io_type: old_type} = socket.assigns

    if connected?(socket) do
      StreamBridge.unsubscribe(ns, operative_id, old_type)
      StreamBridge.subscribe(ns, operative_id, new_type)
    end

    {:noreply,
     assign(socket,
       io_type: new_type,
       status: :connecting,
       messages: [],
       message_count: 0
     )}
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
  def handle_info({:stream_status, status}, socket) do
    case status do
      :connected ->
        {:noreply, assign(socket, status: :connected)}

      {:error, _reason} ->
        {:noreply, assign(socket, status: :error)}
    end
  end

  @impl true
  def handle_info({:stream_message, msg}, socket) do
    if socket.assigns.paused do
      {:noreply, assign(socket, message_count: socket.assigns.message_count + 1)}
    else
      messages =
        [msg | socket.assigns.messages]
        |> Enum.take(@max_messages)

      {:noreply,
       assign(socket,
         messages: messages,
         message_count: socket.assigns.message_count + 1
       )}
    end
  end

  defp filtered_messages(messages, ""), do: messages

  defp filtered_messages(messages, filter) do
    case Regex.compile(filter) do
      {:ok, regex} ->
        Enum.filter(messages, fn msg ->
          Regex.match?(regex, msg.message)
        end)

      _ ->
        messages
    end
  end
end
