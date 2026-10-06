defmodule FlezhaUiWeb.PluginLive do
  @moduledoc """
  The plugins enabled in each namespace the bound token can reach, the relays
  bound to each, and the plugin packages installed on the controller.

  The same screen serves one namespace at `/namespaces/:ns/plugins`. The
  controller answers the plugins of one namespace per call, so the scoped
  screen reads that namespace alone: the scope is the controller's, not a
  filter applied here.
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
    token = socket.assigns.flezha_token
    {catalog, catalog_error} = NodeManager.ok_or_error(NodeManager.installed_plugins(token), [])
    {providers, providers_error} = NodeManager.ok_or_error(NodeManager.providers(token), [])

    socket
    |> assign(
      available_providers: providers,
      providers_error: providers_error,
      catalog: catalog,
      catalog_error: catalog_error
    )
    |> assign_plugins()
  end

  # One read per namespace. A namespace the controller refuses is stated on
  # its own, so the others still list.
  defp assign_plugins(socket) do
    token = socket.assigns.flezha_token

    namespaces =
      case socket.assigns.scoped_namespace do
        nil -> token |> NodeManager.scoped_namespaces() |> elem(0)
        scope -> [scope]
      end

    {plugins, refused} =
      Enum.reduce(namespaces, {[], []}, fn namespace, {plugins, refused} ->
        case NodeManager.plugins(namespace, token) do
          {:ok, rows} -> {plugins ++ Enum.map(rows, &Map.put(&1, :namespace, namespace)), refused}
          {:error, reason} -> {plugins, refused ++ [{namespace, reason}]}
        end
      end)

    assign(socket, plugins: Enum.sort_by(plugins, &{&1.namespace, &1.name}), refused: refused)
  end

  @impl true
  def handle_event("confirm_disable", %{"name" => name, "namespace" => namespace}, socket) do
    {:noreply, assign(socket, confirm_disable: %{name: name, namespace: namespace})}
  end

  @impl true
  def handle_event("cancel_disable", _params, socket) do
    {:noreply, assign(socket, confirm_disable: nil)}
  end

  @impl true
  def handle_event("disable_plugin", %{"name" => name, "namespace" => namespace}, socket) do
    case NodeManager.disable_plugin(name, namespace, socket.assigns.flezha_token) do
      :ok ->
        {:noreply,
         socket
         |> assign(confirm_disable: nil)
         |> assign_plugins()
         |> put_flash(:info, "Plugin #{name} disabled.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_disable: nil)
         |> put_flash(:error, disable_error(name, reason))}
    end
  end

  defp join_or_dash(list) when list in [nil, []], do: "—"
  defp join_or_dash(list), do: Enum.join(list, ", ")

  defp disable_error(name, reason) do
    case NodeManager.error(reason) do
      %{code: "plugin.not_found"} -> "The controller does not know a plugin named #{name}."
      _other -> error_message(reason, "the disable")
    end
  end
end
