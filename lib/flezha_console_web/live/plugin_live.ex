defmodule FlezhaConsoleWeb.PluginLive do
  @moduledoc """
  The plugins enabled in each namespace the bound token can reach, the relays
  bound to each, and the plugin packages installed on the controller.

  The same screen serves one namespace at `/namespaces/:ns/plugins`. The
  controller answers the plugins of one namespace per call, so the scoped
  screen reads that namespace alone: the scope is the controller's, not a
  filter applied here.

  Plugins are enabled, bound to further relays and given new options here
  through `FlezhaConsoleWeb.Live.PluginForm`, the form the relay screen attaches with.

  A provider is presented by what it does — its description and the hooks it
  supports, as the controller declares them — with its module on request.
  Each provider is described once per screen, never on the tick.

  A namespace may enable as many plugins as it runs relays, each bound to
  thousands, so the listing reads one page per namespace, searched and
  filtered by the controller, and each row carries a sample of its relays.
  """

  use FlezhaConsoleWeb, :live_view

  use FlezhaConsoleWeb.Live.Refresh, every: 5_000, background: true
  use FlezhaConsoleWeb.Live.PluginForm
  use FlezhaConsoleWeb.Inspect, kinds: ~w(plugin)
  use FlezhaConsoleWeb.Live.Sections, open: %{"providers" => false}

  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.ListingView
  alias FlezhaConsoleWeb.Live.PluginForm
  alias FlezhaConsoleWeb.Live.Sections

  @listing "plugins"

  @view ListingView.declare(
          search: :text,
          filters: [provider: :provider, relay: :relay],
          sorts: [name: "By name"]
        )

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
       total: 0,
       view: ListingView.default(@view),
       unbind_other: nil,
       refused: [],
       namespaces_error: nil,
       available_providers: [],
       refused_packages: %{},
       unreachable: [],
       providers_error: nil,
       catalog: [],
       catalog_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    title = Layouts.scoped_title("Plugins", socket.assigns.scoped_namespace)
    view = ListingView.parse(@view, params)
    # Opening an inspector patches the address too; only a new scope or view
    # reads again.
    socket =
      if socket.assigns.loaded? and view == socket.assigns.view and
           socket.assigns[:loaded_scope] == socket.assigns.scoped_namespace,
         do: socket,
         else:
           socket
           |> assign(page_title: title, view: view, loaded_scope: socket.assigns.scoped_namespace)
           |> read_when_connected()

    {:noreply, inspect_params(socket, params)}
  end

  @doc "The address of the listing `view` asks for, its view in the query string."
  def view_path(nil, view), do: ~p"/plugins?#{ListingView.query(@view, view)}"

  def view_path(scope, view),
    do: ~p"/namespaces/#{scope}/plugins?#{ListingView.query(@view, view)}"

  @doc "Whether the operator searched or filtered the listing."
  def searched?(view), do: view != ListingView.default(@view)

  @doc "The sample of a plugin's relays its row shows, and how many more it is bound to."
  def relays_more(plugin), do: max((plugin[:relay_count] || 0) - length(plugin[:relays] || []), 0)

  @impl FlezhaConsoleWeb.Inspect
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

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_read(socket) do
    %{flezha_token: token, scoped_namespace: scope, view: view, provider_details: known} =
      socket.assigns

    opts = ListingView.opts(@view, view, Sections.limit(socket.assigns.paging, @listing))

    fn ->
      installed = NodeManager.installed_plugins(token)
      listed = NodeManager.providers(token)
      plugins = read_plugins(scope, token, opts)
      providers = NodeManager.ok_or(listed, [])

      ids =
        (Enum.map(plugins.plugins, &provider_id/1) ++ Enum.map(providers, &to_string(&1.id)))
        |> Enum.uniq()
        |> Enum.reject(&Map.has_key?(known, &1))

      %{
        installed: installed,
        listed: listed,
        plugins: plugins,
        details: describe(ids, token)
      }
    end
  end

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_apply(socket, {:ok, read}) do
    {catalog, catalog_error} = NodeManager.ok_or_error(read.installed, [])

    {listing, providers_error} =
      case read.listed do
        {:ok, listing} -> {listing, nil}
        {:error, reason} -> {%{rows: [], refused: %{}}, reason}
      end

    socket
    |> assign(read.plugins)
    |> assign(
      loaded?: true,
      available_providers: listing.rows,
      refused_packages: listing.refused,
      providers_error: providers_error,
      catalog: installed_rows(catalog),
      catalog_error: catalog_error,
      unreachable: NodeManager.unreachable([read.installed, read.listed]),
      provider_details: Map.merge(socket.assigns.provider_details, read.details)
    )
  end

  def refresh_apply(socket, {:exit, _reason}),
    do: assign(socket, loaded?: true, namespaces_error: :read_failed)

  @doc false
  def listing_grown(socket, @listing), do: refresh(socket)
  def listing_grown(socket, _id), do: socket

  @doc """
  The installed packages once per id, version and status, with the
  controllers holding each copy in `nodes`: copies that agree are one row.
  """
  def installed_rows(catalog) do
    catalog
    |> NodeManager.copies(&{&1[:id], &1[:version], &1[:status]})
    |> Enum.map(fn {first, copies} ->
      Map.put(first, :nodes, NodeManager.row_controllers(copies))
    end)
    |> Enum.sort_by(&{to_string(&1[:id]), to_string(&1[:version])})
  end

  @doc ~S|"The controller refused 1 installed package", or per controller when their counts differ; nil for none.|
  def refused_words(refused) when is_map(refused) do
    case refused |> Map.values() |> Enum.uniq() do
      [0] ->
        nil

      [count] when map_size(refused) == 1 ->
        "The controller refused #{Words.count(count, "installed package")} at boot"

      [count] ->
        "Each controller refused #{Words.count(count, "installed package")} at boot"

      _differ ->
        refused
        |> Enum.reject(fn {_node, count} -> count == 0 end)
        |> Enum.sort()
        |> Enum.map(fn {node, count} -> "#{node} refused #{Words.count(count, "package")}" end)
        |> Words.join()
        |> Kernel.<>(" at boot")
    end
  end

  def refused_words(_refused), do: nil

  @doc """
  The controllers of `answered` that cannot enable `provider`, or `[]` when
  every one can.
  """
  def lacking(provider, answered),
    do: answered |> Enum.reject(&(&1 in (provider[:nodes] || answered))) |> Enum.sort()

  # One page per namespace, merged by namespace. A namespace the controller
  # refuses is stated on its own, so the others still list.
  defp read_plugins(scope, token, opts) do
    {namespaces, namespaces_error} = NodeManager.namespaces_in_scope(scope, token)

    {plugins, total, refused} =
      Enum.reduce(namespaces, {[], 0, []}, fn namespace, {plugins, total, refused} ->
        case NodeManager.plugins(namespace, token, opts) do
          {:ok, %{rows: rows, total: count}} ->
            {plugins ++ Enum.map(rows, &Map.put(&1, :namespace, namespace)), total + count,
             refused}

          {:error, reason} ->
            {plugins, total, refused ++ [{namespace, reason}]}
        end
      end)

    %{
      plugins: Enum.take(plugins, opts[:limit]),
      total: total,
      refused: refused,
      namespaces_error: namespaces_error
    }
  end

  # Each provider in view, described once: its help's first paragraph and its
  # hooks. A provider the controller will not describe is listed by name.
  defp describe(ids, token) do
    Map.new(ids, fn id ->
      case NodeManager.provider(id, token) do
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
  end

  defp summary(nil), do: nil

  defp summary(help) do
    help |> to_string() |> String.split(~r/\n\s*\n/, parts: 2) |> hd() |> String.trim()
  end

  @impl true
  def handle_event("view", %{"view" => params}, socket) do
    view = Map.merge(socket.assigns.view, ListingView.parse(@view, params))
    {:noreply, push_patch(socket, to: view_path(socket.assigns.scoped_namespace, view))}
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
         |> refresh()
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

  # A plugin bound to more relays than its row shows is unbound from any of
  # them through a relay search; the binding is confirmed before the
  # confirmation opens, since the row holds only a sample.
  @impl true
  def handle_event("unbind_other_open", %{"name" => name, "namespace" => namespace}, socket) do
    other = %{name: name, namespace: namespace, relay: ""}
    {:noreply, assign(socket, unbind_other: pick_relays(other, "", socket.assigns.flezha_token))}
  end

  def handle_event("unbind_other_search", %{"value" => query}, socket)
      when is_binary(query) and byte_size(query) <= 256 do
    other = pick_relays(socket.assigns.unbind_other, query, socket.assigns.flezha_token)
    {:noreply, assign(socket, unbind_other: other)}
  end

  def handle_event("unbind_other_change", %{"unbind" => %{"relay" => relay}}, socket) do
    {:noreply, update(socket, :unbind_other, &%{&1 | relay: relay, error: nil})}
  end

  def handle_event("unbind_other_close", _params, socket),
    do: {:noreply, assign(socket, unbind_other: nil)}

  def handle_event("unbind_other_next", _params, %{assigns: %{unbind_other: other}} = socket)
      when other.relay != "" do
    %{name: name, namespace: namespace, relay: relay} = other

    if bound?(namespace, name, relay, socket.assigns.flezha_token),
      do:
        {:noreply,
         assign(socket,
           unbind_other: nil,
           confirm_unbind: %{name: name, namespace: namespace, relay: relay}
         )},
      else: {:noreply, assign(socket, unbind_other: %{other | error: :not_bound})}
  end

  def handle_event("unbind_other_next", _params, socket), do: {:noreply, socket}

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
         |> refresh()
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

  defp pick_relays(other, query, token),
    do:
      Map.merge(
        other,
        PluginForm.relay_matches(other.namespace, query, token)
      )

  defp bound?(namespace, name, relay, token) do
    case NodeManager.plugins(namespace, token, filter: [relay: relay, text: name]) do
      {:ok, %{rows: rows}} -> Enum.any?(rows, &(to_string(&1.name) == name))
      {:error, _reason} -> false
    end
  end

  defp disable_error(name, reason) do
    case NodeManager.error(reason) do
      %{code: "plugin.not_found"} -> "The controller does not know a plugin named #{name}."
      _other -> error_message(reason, "the disable")
    end
  end
end
