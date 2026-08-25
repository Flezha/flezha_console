defmodule FlezhaUiWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use FlezhaUiWeb, :controller` and
  `use FlezhaUiWeb, :live_view`.
  """
  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager

  @theme_hydrate_path Path.expand(
                        "../../../assets/node_modules/@flezha/stylebook/js/theme-hydrate.js",
                        __DIR__
                      )

  File.exists?(@theme_hydrate_path) ||
    raise """
    flezha-stylebook is not installed, so the theme cannot be hydrated before
    first paint and every page would flash the wrong theme.

    Run `mix assets.setup`.
    """

  @external_resource @theme_hydrate_path
  @theme_hydrate File.read!(@theme_hydrate_path)

  embed_templates "layouts/*"

  @doc """
  The rail's destinations, grouped and labelled, for a given scope.

  The one list of where the console can be navigated to: the sidebar renders
  it, the command palette indexes it, and `nav_current?/2` marks it — so a
  destination cannot exist in one and be missing from another.

  A screen belongs to `NAMESPACE` only when the controller call behind it takes
  a namespace or the rows it returns each carry one. Dead-letter is keyed by
  operative class and the observability calls take no namespace at all, so both
  stay platform-global rather than being dressed as scoped.

  With no namespace in force the scoped group has nothing honest to point at,
  so it comes back empty and the rail says so.
  """
  def nav_sections(namespace) do
    [
      %{heading: "Namespace", scope: namespace, entries: scoped_entries(namespace)},
      %{
        heading: "Platform",
        scope: nil,
        entries: [
          entry(~p"/", "hero-squares-2x2", "Dashboard"),
          entry(~p"/operatives", "hero-cpu-chip", "Fleet"),
          entry(~p"/namespaces", "hero-rectangle-stack", "Namespaces"),
          entry(~p"/cluster", "hero-server-stack", "Cluster"),
          entry(~p"/controller", "hero-server", "Controller"),
          entry(~p"/observability", "hero-signal", "Observability"),
          entry(~p"/dlq", "hero-inbox-stack", "Dead-letter"),
          entry(~p"/audit", "hero-document-text", "Audit log")
        ]
      }
    ]
  end

  defp scoped_entries(nil), do: []

  defp scoped_entries(namespace) do
    [
      entry(scoped_path(namespace, nil), "hero-home", "Overview"),
      entry(scoped_path(namespace, "operatives"), "hero-cpu-chip", "Operatives"),
      entry(scoped_path(namespace, "plugins"), "hero-puzzle-piece", "Plugins"),
      entry(scoped_path(namespace, "schedules"), "hero-clock", "Schedules")
    ]
  end

  defp entry(path, icon, label), do: %{path: path, icon: icon, label: label}

  @doc """
  A namespace's screen, by the collection segment that names it.

  Written out per collection because a verified route is checked against the
  router, and a path built from two interpolated segments matches none of them.
  """
  def scoped_path(namespace, nil), do: ~p"/namespaces/#{namespace}"
  def scoped_path(namespace, "operatives"), do: ~p"/namespaces/#{namespace}/operatives"
  def scoped_path(namespace, "plugins"), do: ~p"/namespaces/#{namespace}/plugins"
  def scoped_path(namespace, "schedules"), do: ~p"/namespaces/#{namespace}/schedules"

  # A crumb for a screen the operator did not name. Everything else on a path
  # is an identifier the controller chose, and is shown as it is spelled.
  @crumb_labels %{
    "namespaces" => "Namespaces",
    "operatives" => "Operatives",
    "plugins" => "Plugins",
    "schedules" => "Schedules",
    "stream" => "Stream",
    "state" => "State"
  }

  @doc """
  Assigns what the shell needs to state where the operator is.

  `:current_path` marks the current destination, `:breadcrumbs` says where it
  sits, and `:scoped_namespace` is the namespace the route puts in force —
  read from the address bar every time rather than remembered, so a pasted
  link opens the scope it names.

  Server-side rather than in JavaScript: a client-set `aria-current` loses the
  race with LiveView's first DOM patch on a hard page load, and is dropped.

  The picker's namespaces are resolved once per mount instead: they change
  rarely, and a screen ticking every two seconds would otherwise pay a
  controller round-trip per tick for a control it is not using.
  """
  def on_mount(:current_path, _params, _session, socket) do
    socket =
      Phoenix.Component.assign_new(socket, :shell_namespaces, fn ->
        socket.assigns[:current_scope]
        |> FlezhaUi.Accounts.Scope.flezha_token()
        |> NodeManager.scoped_namespaces()
        |> elem(0)
        |> Enum.sort()
      end)

    {:cont,
     Phoenix.LiveView.attach_hook(socket, :current_path, :handle_params, fn _params,
                                                                            uri,
                                                                            socket ->
       path = URI.parse(uri).path

       {:cont,
        Phoenix.Component.assign(socket,
          current_path: path,
          breadcrumbs: breadcrumbs(path),
          scoped_namespace: scoped_namespace(path)
        )}
     end)}
  end

  @doc """
  Whether a navigation destination is the page being shown.

  An entry owns the subtree below it, measured from its own scope: the
  dashboard and a namespace's Overview both sit at the root of theirs, so both
  are exact matches, and Operatives still owns the operative below it. Entries
  in different scopes never match, which is what keeps `/namespaces/x/operatives`
  from marking the platform Fleet entry as well as the namespace's own.
  """
  def nav_current?(current, path) do
    case {split_scope(current), split_scope(path)} do
      {{scope, below}, {scope, []}} -> below == []
      {{scope, below}, {scope, entry}} -> List.starts_with?(below, entry)
      _differing -> false
    end
  end

  # A path as `{namespace, the segments below it}`, or `{nil, its segments}`
  # when it carries no scope. Every question the shell asks about a route —
  # what is in scope, what the rail marks, where the picker goes — is asked of
  # this one reading, and asked in segments so `/operatives` cannot be read as
  # a prefix of `/operativesomething`.
  defp split_scope(path) do
    case segments(path) do
      ["namespaces", namespace | below] -> {namespace, below}
      platform -> {nil, platform}
    end
  end

  defp segments(path), do: String.split(path || "", "/", trim: true)

  @doc """
  The namespace a path puts in scope, or `nil` when it is a platform screen.

      iex> FlezhaUiWeb.Layouts.scoped_namespace("/namespaces/default/plugins")
      "default"
      iex> FlezhaUiWeb.Layouts.scoped_namespace("/namespaces")
      nil
  """
  def scoped_namespace(path), do: split_scope(path) |> elem(0)

  @doc """
  A screen's title with the namespace it is scoped to, or plain when it is not.

  One decoration for all three scoped screens, so the shell names a scope the
  same way wherever it appears.
  """
  def scoped_title(base, nil), do: base
  def scoped_title(base, namespace), do: "#{base} · #{namespace}"

  @doc """
  Where the namespace picker goes when `namespace` is chosen from `current`.

  One meaning in both places: show me this namespace. From anywhere under a
  scoped collection that is the same collection under the new scope — including
  from one operative of it, whose id means nothing under the new namespace, so
  the collection is as close as the screen kind survives. From a platform
  screen it is the namespace's own overview.
  """
  def scope_target(current, namespace) do
    case split_scope(current) do
      {_scope, [collection | _below]} when collection in ~w(operatives plugins schedules) ->
        scoped_path(namespace, collection)

      _otherwise ->
        scoped_path(namespace, nil)
    end
  end

  @doc """
  The crumb trail for a path, as `%{label:, path:}` from the root down.

  The last crumb carries no path: it is the page being read. A path with one
  segment or none is a top-level screen and gets no trail at all.
  """
  def breadcrumbs(path) do
    segments = segments(path)
    last = length(segments) - 1

    if last < 1 do
      []
    else
      segments
      |> Enum.with_index()
      |> Enum.map_reduce("", fn {segment, index}, prefix ->
        href = prefix <> "/" <> segment
        {%{label: crumb_label(segment, index), path: if(index != last, do: href)}, href}
      end)
      |> elem(0)
    end
  end

  # Every route below the top level alternates a collection with one member of
  # it, so an even segment names a screen and an odd one is an identifier.
  # Reading the position rather than the word keeps a namespace called
  # "operatives" from being relabelled as the screen of that name.
  defp crumb_label(segment, index) when rem(index, 2) == 0,
    do: Map.get(@crumb_labels, segment, Phoenix.Naming.humanize(segment))

  defp crumb_label(segment, _index), do: segment

  @doc """
  The stylebook's pre-paint theme hydration, inlined verbatim.

  Read at compile time and registered as an external resource, so editing the
  stylebook recompiles this module and the page pays no second blocking
  request for six lines of script.
  """
  def theme_hydrate, do: Phoenix.HTML.raw(@theme_hydrate)
end
