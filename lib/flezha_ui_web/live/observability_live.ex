defmodule FlezhaUiWeb.ObservabilityLive do
  @moduledoc """
  What the controller is emitting, where it goes, and a live view of it.

  The tail rides `FlezhaUi.Service.EventFeed`, the same feed the runtime events
  use: `Observability.tail/2` forwards each signal to the feed's pid, narrowed
  by the controller to what the bound token may see.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000
  use FlezhaUiWeb.Live.Tail, tag: :observability_tail, max: 200

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> init_tail()
     |> assign(
       page_title: "Observability",
       sources: [],
       sinks: [],
       load_error: nil,
       disabled?: false,
       toggle_error: nil
     )
     |> refresh()}
  end

  @doc """
  A forwarded signal, as a plain map. The controller sends its
  `%Flezha.Observability.Signal{}` struct, which this node has no module for
  and which `Access` cannot read.
  """
  @impl FlezhaUiWeb.Live.Tail
  def unwrap_tail(signal) when is_map(signal), do: Map.delete(signal, :__struct__)

  @impl true
  def handle_event("toggle_source", %{"source" => name}, socket) do
    case named_source(socket, name) do
      nil -> {:noreply, socket}
      source -> {:noreply, socket |> apply_toggle(source) |> refresh()}
    end
  end

  @impl true
  def handle_event("start_tail", %{"source" => name}, socket) do
    case named_source(socket, name) do
      nil ->
        {:noreply, socket}

      source ->
        token = socket.assigns.flezha_token
        open = &NodeManager.observability_tail(source[:name], token, &1)

        {:noreply, start_tail(socket, open, source[:name])}
    end
  end

  @impl true
  def handle_event("stop_tail", _params, socket) do
    {:noreply, stop_tail(socket)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token

    case NodeManager.observability_sources(token) do
      {:ok, sources} ->
        assign(socket,
          sources: sources,
          sinks: NodeManager.ok_or(NodeManager.observability_sinks(token), []),
          load_error: nil,
          disabled?: false
        )

      {:error, reason} ->
        if NodeManager.error(reason).code == "observability.disabled",
          do: assign(socket, sources: [], sinks: [], load_error: nil, disabled?: true),
          else: assign(socket, sources: [], sinks: [], load_error: reason, disabled?: false)
    end
  end

  @doc "Whether a tail was refused because the controller's pubsub sink is off."
  def pubsub_disabled?(nil), do: false

  def pubsub_disabled?(error),
    do: NodeManager.error(error).code == "observability.pubsub_disabled"

  # The listing's own entry, found by the name a form sent. The source atom is
  # then the one the controller named — a form value is never converted.
  defp named_source(socket, name) do
    Enum.find(socket.assigns.sources, &(to_string(&1[:name]) == name))
  end

  defp apply_toggle(socket, source) do
    token = socket.assigns.flezha_token

    result =
      if NodeManager.source_enabled?(source) do
        NodeManager.disable_source(source[:name], token)
      else
        NodeManager.enable_source(source[:name], token)
      end

    case result do
      {:error, reason} -> assign(socket, toggle_error: reason)
      _ok -> assign(socket, toggle_error: nil)
    end
  end
end
