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
       source_filter: "",
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
  def handle_event("filter_sources", %{"q" => text}, socket) do
    {:noreply, assign(socket, source_filter: text)}
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

  @areas [
    {:relay, "Relay runtime", ~w(relay steps state mailbox runner reconcile health convergence)},
    {:plugins, "Plugins and transports", ~w(hook http file plugin transport kafka websocket)},
    {:vm, "The virtual machine and host", ~w(beam_vm vm host)}
  ]

  @doc """
  The sources grouped by area — relay runtime, plugins and transports,
  platform, the virtual machine and host — each group with its sources whose
  name contains `filter`, and how many of all its sources are enabled.
  """
  def groups(sources, filter) do
    needle = filter |> String.trim() |> String.downcase()

    sources
    |> Enum.group_by(&area(to_string(&1[:name])))
    |> Enum.map(fn {{key, label}, members} ->
      %{
        key: key,
        label: label,
        enabled: Enum.count(members, &NodeManager.source_enabled?/1),
        total: length(members),
        sources:
          members
          |> Enum.filter(&String.contains?(String.downcase(to_string(&1[:name])), needle))
          |> Enum.sort_by(&to_string(&1[:name]))
      }
    end)
    |> Enum.sort_by(fn group ->
      Enum.find_index([:relay, :plugins, :platform, :vm], &(&1 == group.key))
    end)
  end

  defp area(name) do
    Enum.find_value(@areas, {:platform, "Platform"}, fn {key, label, words} ->
      if Enum.any?(words, &String.contains?(name, &1)), do: {key, label}
    end)
  end

  @doc """
  A signal's measurements as `key value` pairs. Its own timestamp is the
  emitting node's monotonic clock, which says nothing to a reader, so it is
  not shown; the newest signal is on top.
  """
  def measurements(values) when is_map(values) do
    values
    |> Enum.sort()
    |> Enum.map_join("  ", fn {key, value} -> "#{key} #{figure(value)}" end)
  end

  def measurements(other), do: inspect(other)

  defp figure(value) when is_float(value), do: value |> Float.round(4) |> to_string()
  defp figure(value), do: FlezhaUi.Format.printable(value)

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
