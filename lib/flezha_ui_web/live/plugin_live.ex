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

  A provider is presented by what it does — its description and the hooks it
  supports, as the controller declares them — with its module on request.
  Each provider is described once per screen, never on the tick.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000
  use FlezhaUiWeb.Live.PluginForm
  use FlezhaUiWeb.Inspect, kinds: ~w(plugin)
  use FlezhaUiWeb.Live.Sections, open: %{"providers" => false}

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> plugin_form_init()
     |> sections_init()
     |> assign(
       confirm_disable: nil,
       confirm_unbind: nil,
       page_title: "Plugins",
       loaded?: false,
       provider_details: %{},
       plugins: [],
       refused: [],
       available_providers: [],
       refused_packages: 0,
       providers_error: nil,
       catalog: [],
       catalog_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    title = Layouts.scoped_title("Plugins", socket.assigns.scoped_namespace)
    # Opening an inspector patches the address too; only a new scope reads again.
    socket =
      if socket.assigns.loaded? and
           socket.assigns[:loaded_scope] == socket.assigns.scoped_namespace,
         do: socket,
         else:
           socket
           |> assign(page_title: title, loaded_scope: socket.assigns.scoped_namespace)
           |> refresh_when_connected()

    {:noreply, inspect_params(socket, params)}
  end

  @impl FlezhaUiWeb.Inspect
  def inspect_context(socket, {"plugin", key}) do
    {namespace, name} =
      case {socket.assigns.scoped_namespace, String.split(key, "/", parts: 2)} do
        {nil, [ns, name]} -> {ns, name}
        {scope, _parts} -> {scope, key}
      end

    case Enum.find(socket.assigns.plugins, &(&1.name == name and &1.namespace == namespace)) do
      nil ->
        %{namespace: namespace}

      plugin ->
        %{
          namespace: namespace,
          provider: plugin.provider,
          provider_id: provider_id(plugin),
          hooks: Enum.map(plugin[:hooks] || [], &to_string/1),
          relays: Enum.map(plugin[:relays] || [], &to_string/1),
          controllers: Enum.map(plugin[:controllers] || [], &to_string/1)
        }
    end
  end

  def inspect_context(_socket, _selection), do: %{}

  @doc "How a plugin is named in `?inspect=`: with its namespace on an unscoped screen."
  def inspect_id(plugin, nil), do: "#{plugin.namespace}/#{plugin.name}"
  def inspect_id(plugin, _scope), do: plugin.name

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token
    {catalog, catalog_error} = NodeManager.ok_or_error(NodeManager.installed_plugins(token), [])

    {listing, providers_error} =
      NodeManager.ok_or_error(NodeManager.providers(token), %{providers: [], refused: 0})

    socket
    |> assign(
      loaded?: true,
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

    socket
    |> assign(plugins: Enum.sort_by(plugins, &{&1.namespace, &1.name}), refused: refused)
    |> describe_providers()
  end

  # Each provider in view, described once: its help's first paragraph and its
  # hooks. A provider the controller will not describe is listed by name.
  defp describe_providers(socket) do
    %{plugins: plugins, available_providers: providers, provider_details: known} = socket.assigns

    ids =
      (Enum.map(plugins, &provider_id/1) ++ Enum.map(providers, &to_string(&1.id)))
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(known, &1))

    details =
      Map.new(ids, fn id ->
        case NodeManager.provider(id, socket.assigns.flezha_token) do
          {:ok, provider} ->
            {id,
             %{
               description: summary(provider[:help]),
               hooks: Enum.map(provider[:hooks] || [], &to_string/1)
             }}

          {:error, _reason} ->
            {id, %{description: nil, hooks: []}}
        end
      end)

    assign(socket, provider_details: Map.merge(known, details))
  end

  defp summary(nil), do: nil

  defp summary(help) do
    help |> to_string() |> String.split(~r/\n\s*\n/, parts: 2) |> hd() |> String.trim()
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
