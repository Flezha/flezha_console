defmodule FlezhaUiWeb.PluginLive do
  use FlezhaUiWeb, :live_view

  alias FlezhaUi.Service.NodeManager

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)
    {:ok, assign(socket, plugins: load_plugins(), confirm_disable: nil, page_title: "Plugins")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign(socket, plugins: load_plugins())}
  end

  @impl true
  def handle_event("confirm_disable", %{"plugin_id" => plugin_id}, socket) do
    {:noreply, assign(socket, confirm_disable: plugin_id)}
  end

  @impl true
  def handle_event("cancel_disable", _params, socket) do
    {:noreply, assign(socket, confirm_disable: nil)}
  end

  @impl true
  def handle_event("disable_plugin", %{"plugin_id" => plugin_id}, socket) do
    case NodeManager.disable_plugin(plugin_id) do
      {:ok, _} ->
        socket =
          socket
          |> assign(confirm_disable: nil, plugins: load_plugins())
          |> put_flash(:info, "Plugin #{plugin_id} disabled.")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_disable: nil)
         |> put_flash(:error, "Failed: #{inspect(reason)}")}
    end
  end

  defp load_plugins do
    case NodeManager.get_plugins() do
      map when is_map(map) ->
        Enum.map(map, fn {plugin_id, {module, info}} ->
          ns = if is_map(info), do: Map.get(info, :namespace) || Map.get(info, "namespace"), else: nil
          proc = if is_map(info), do: Map.get(info, :processor_id) || Map.get(info, "processor_id"), else: nil
          trigger = if is_map(info), do: Map.get(info, :trigger) || Map.get(info, "trigger"), else: nil

          %{
            id: to_string(plugin_id),
            module: inspect(module),
            namespace: ns,
            processor_id: proc,
            trigger: trigger
          }
        end)

      _ ->
        []
    end
  end
end
