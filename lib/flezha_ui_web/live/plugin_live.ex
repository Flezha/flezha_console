defmodule FlezhaUiWeb.PluginLive do
  @moduledoc """
  The plugins enabled across the controller, and what each is bound to.

  The same screen serves one namespace at `/namespaces/:ns/plugins`. The
  controller exposes no namespaced plugin call — `get_plugins/0` answers the
  lot — so the scope is a filter over the namespace each enabled plugin already
  carries, applied here. The screen says so, because a filtered count read as a
  controller-side guarantee would be read wrong.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> assign(confirm_disable: nil, page_title: "Plugins")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    title = Layouts.scoped_title("Plugins", socket.assigns.scoped_namespace)

    {:noreply, socket |> assign(page_title: title) |> refresh()}
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    {catalog, catalog_error} = NodeManager.ok_or_error(NodeManager.installed_plugins(), [])

    socket
    |> assign(
      available_providers: NodeManager.providers(),
      catalog: catalog,
      catalog_error: catalog_error
    )
    |> assign_plugins()
  end

  defp assign_plugins(socket) do
    plugins = NodeManager.in_namespace(load_plugins(), socket.assigns.scoped_namespace)

    assign(socket, plugins: plugins)
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
          |> assign(confirm_disable: nil)
          |> assign_plugins()
          |> put_flash(:info, "Plugin #{plugin_id} disabled.")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_disable: nil)
         |> put_flash(:error, "Failed: #{inspect(reason)}")}
    end
  end

  # The plugin registry answers `%{plugin_id => {namespace, operative_id}}`;
  # provider and subscribed extensions live on the target operative's extension
  # table, so each distinct operative is read once and joined in.
  defp load_plugins do
    case NodeManager.get_plugins() do
      map when is_map(map) ->
        targets = Enum.map(map, fn {_id, target} -> plugin_target(target) end)
        entries = extension_entries_by_plugin(targets)

        map
        |> Enum.map(fn {plugin_id, target} ->
          id = to_string(plugin_id)
          {ns, operative_id} = plugin_target(target)
          matched = Map.get(entries, id, [])

          %{
            id: id,
            namespace: ns,
            operative_id: operative_id,
            provider: matched |> Enum.map(& &1.provider) |> Enum.uniq() |> join_or_dash(),
            extensions: matched |> Enum.map(& &1.extension) |> Enum.sort() |> join_or_dash()
          }
        end)
        |> Enum.sort_by(& &1.id)

      _ ->
        []
    end
  end

  defp plugin_target({ns, operative_id}), do: {ns, operative_id}
  defp plugin_target(_), do: {nil, nil}

  defp extension_entries_by_plugin(targets) do
    targets
    |> Enum.uniq()
    |> Enum.filter(fn {ns, operative_id} -> is_binary(ns) and is_binary(operative_id) end)
    |> Enum.flat_map(fn {ns, operative_id} ->
      case NodeManager.overwatch_facts(ns, operative_id) do
        {:ok, facts} -> facts.bindings
        _ -> []
      end
    end)
    |> Enum.group_by(& &1.plugin_id)
  end

  defp join_or_dash([]), do: "—"
  defp join_or_dash(list), do: Enum.join(list, ", ")
end
