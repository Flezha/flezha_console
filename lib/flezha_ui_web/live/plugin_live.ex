defmodule FlezhaUiWeb.PluginLive do
  @moduledoc """
  The plugins enabled in each namespace the bound token can reach, the relays
  bound to each, and the plugin packages installed on the controller.

  The same screen serves one namespace at `/namespaces/:ns/plugins`. The
  controller answers the plugins of one namespace per call, so the scoped
  screen reads that namespace alone: the scope is the controller's, not a
  filter applied here.

  Plugins are enabled, bound to further relays and given new options here
  through `FlezhaUiWeb.Live.PluginForm`, the form the relay screen attaches with.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000
  use FlezhaUiWeb.Live.PluginForm

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> plugin_form_init()
     |> assign(confirm_disable: nil, confirm_unbind: nil, page_title: "Plugins")}
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

    {listing, providers_error} =
      NodeManager.ok_or_error(NodeManager.providers(token), %{providers: [], refused: 0})

    socket
    |> assign(
      available_providers: listing.providers,
      refused_packages: listing.refused,
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

  @impl true
  def handle_event("confirm_unbind", params, socket) do
    %{"name" => name, "namespace" => namespace, "relay" => relay} = params
    {:noreply, assign(socket, confirm_unbind: %{name: name, namespace: namespace, relay: relay})}
  end

  @impl true
  def handle_event("cancel_unbind", _params, socket) do
    {:noreply, assign(socket, confirm_unbind: nil)}
  end

  @impl true
  def handle_event(
        "unbind_plugin",
        %{"name" => name, "namespace" => namespace, "relay" => relay},
        socket
      ) do
    case NodeManager.unbind_plugin(name, namespace, relay, socket.assigns.flezha_token) do
      :ok ->
        {:noreply,
         socket
         |> assign(confirm_unbind: nil)
         |> assign_plugins()
         |> put_flash(:info, "#{relay} unbound from plugin #{name}, which stays enabled.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_unbind: nil)
         |> put_flash(:error, error_message(reason, "the unbind"))}
    end
  end

  @doc """
  The id an enabled plugin's provider is registered under, which describing it
  takes. A core that answers no `provider_id` gives its name, which is the id
  for most providers.
  """
  def provider_id(plugin), do: to_string(plugin[:provider_id] || plugin.provider)

  @doc """
  Whether an enabled plugin runs on controllers: its provider says so. A
  provider this controller does not describe reads as a relay plugin.
  """
  def controller_plugin?(plugin, providers) do
    Enum.any?(providers, &(to_string(&1.id) == provider_id(plugin) and &1.type == :controller))
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
