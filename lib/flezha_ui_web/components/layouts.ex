defmodule FlezhaUiWeb.Layouts do
  @moduledoc """
  The console's shell — the rail of two sections beside a topbar — and the
  derivation of where the operator is that every screen shares.

  The rail lists the namespace's own screens and the platform's; the topbar
  holds the connection, the namespace picker, the screen's liveness, help, the
  bound identity and the account menu.

  "root" is the document skeleton; "app" wraps every LiveView and the plain
  settings page; "auth" is the signed-out canvas.
  """
  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Attention
  alias FlezhaUiWeb.Glossary
  alias FlezhaUiWeb.Topology

  @theme_hydrate_path Path.expand(
                        "../../../assets/node_modules/@flezha/stylebook/js/theme-hydrate.js",
                        __DIR__
                      )

  File.exists?(@theme_hydrate_path) ||
    raise """
    flezha_stylebook is not installed, so the theme cannot be hydrated before
    first paint and every page would flash the wrong theme.

    Run `mix assets.setup`.
    """

  @external_resource @theme_hydrate_path
  @theme_hydrate File.read!(@theme_hydrate_path)

  @pulse_every 10_000

  embed_templates "layouts/*"

  # ---- Where the operator is ----

  @doc """
  The rail's destinations, grouped and labelled, for a given scope.

  The one list of where the console can be navigated to: the rail renders it,
  the command palette indexes it, and `nav_current?/2` marks it — so a
  destination cannot exist in one and be missing from another.

  A screen belongs to `NAMESPACE` only when the controller call behind it takes
  a namespace or the rows it returns each carry one. Dead-letter is keyed by
  relay class and the observability calls take no namespace at all, so both
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
          entry(~p"/problems", "hero-exclamation-triangle", "Problems", :problems),
          entry(~p"/relays", "hero-cpu-chip", "Fleet"),
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
      entry(scoped_path(namespace, nil), "hero-home", "Home"),
      entry(scoped_path(namespace, "relays"), "hero-cpu-chip", "Relays"),
      entry(scoped_path(namespace, "plugins"), "hero-puzzle-piece", "Plugins"),
      entry(scoped_path(namespace, "schedules"), "hero-clock", "Schedules")
    ]
  end

  defp entry(path, icon, label, count \\ nil),
    do: %{path: path, icon: icon, label: label, count: count}

  @doc """
  Whether a navigation destination is the page being shown.

  An entry owns the subtree below it, measured from its own scope: a
  namespace's Home sits at the root of its scope, so it is an exact match, and
  Relays still owns the relay below it. Entries in different scopes never
  match, which is what keeps `/namespaces/x/relays` from marking the platform
  Fleet entry as well as the namespace's own.
  """
  def nav_current?(current, path) do
    case {split_scope(current), split_scope(path)} do
      {{scope, below}, {scope, []}} -> below == []
      {{scope, below}, {scope, entry}} -> List.starts_with?(below, entry)
      _differing -> false
    end
  end

  @screens Map.new(
             ~w(relays plugins schedules problems dlq namespaces cluster controller observability audit)a,
             &{Atom.to_string(&1), &1}
           )

  @doc """
  The kind of screen a path shows, which help explains, or `nil`.
  """
  def screen(path) do
    case segments(path) do
      ["namespaces", _ns] -> :home
      ["namespaces", _ns, "relays"] -> :relays
      ["namespaces", _ns, "relays", _id] -> :relay_live
      ["namespaces", _ns, "relays", _id, "listen"] -> :relay_listen
      ["namespaces", _ns, "relays", _id, "state"] -> :relay_state
      ["namespaces", _ns, kind] when is_map_key(@screens, kind) -> @screens[kind]
      [kind] when is_map_key(@screens, kind) -> @screens[kind]
      ["users", "settings" | _] -> :settings
      ["dev", "kit"] -> :kit
      _other -> nil
    end
  end

  @doc """
  A relay's three views as tabs: Live, Listen and State. Each is its own
  route, so a view holding a live subscription is not mounted while another
  is read.
  """
  def relay_tabs(namespace, relay_id, current) do
    for {view, label, path} <- [
          {:live, "Live", ~p"/namespaces/#{namespace}/relays/#{relay_id}"},
          {:listen, "Listen", ~p"/namespaces/#{namespace}/relays/#{relay_id}/listen"},
          {:state, "State", ~p"/namespaces/#{namespace}/relays/#{relay_id}/state"}
        ] do
      %{label: label, path: path, current?: view == current, testid: "relay-tab-#{view}"}
    end
  end

  @doc """
  A namespace's screen, by the collection segment that names it.

  Written out per collection because a verified route is checked against the
  router, and a path built from two interpolated segments matches none of them.
  """
  def scoped_path(namespace, nil), do: ~p"/namespaces/#{namespace}"
  def scoped_path(namespace, "relays"), do: ~p"/namespaces/#{namespace}/relays"
  def scoped_path(namespace, "plugins"), do: ~p"/namespaces/#{namespace}/plugins"
  def scoped_path(namespace, "schedules"), do: ~p"/namespaces/#{namespace}/schedules"

  @doc """
  Assigns what the shell needs to state where the operator is.

  `:current_path` marks the current destination, `:breadcrumbs` says where it
  sits, and `:scoped_namespace` is
  the namespace the route puts in force — read from the address bar every
  time, so a pasted link opens the scope it names. `:shell_namespace` is what
  the rail and the picker show: that scope, or on a screen whose address names none, the
  namespace the user last worked in (see `keep_namespace/2`).

  Server-side rather than in JavaScript: a client-set `aria-current` loses the
  race with LiveView's first DOM patch on a hard page load, and is dropped.

  On a connected socket it also starts the shell's pulse (`pulse/1`). The
  chip's namespaces are resolved once per mount: they change rarely, and a
  screen ticking every two seconds would otherwise pay a controller round-trip
  per tick for a control it is not using.
  """
  def on_mount(:current_path, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign_new(:shell_namespaces, fn ->
        socket.assigns[:current_scope]
        |> FlezhaUi.Accounts.Scope.flezha_token()
        |> NodeManager.scoped_namespaces()
        |> elem(0)
        |> Enum.sort()
      end)
      |> Phoenix.Component.assign_new(:last_namespace, fn ->
        socket.assigns.current_scope.user.last_namespace
      end)
      |> Phoenix.Component.assign_new(:shell_pulse, fn -> nil end)
      |> start_pulse()

    {:cont,
     Phoenix.LiveView.attach_hook(socket, :current_path, :handle_params, fn _params,
                                                                            uri,
                                                                            socket ->
       %URI{path: path, query: query} = URI.parse(uri)
       scoped = scoped_namespace(path)

       socket =
         socket
         |> Phoenix.Component.assign(
           current_path: path,
           current_query: URI.decode_query(query || ""),
           breadcrumbs: breadcrumbs(path),
           scoped_namespace: scoped
         )
         |> keep_namespace(scoped)

       {:cont, socket}
     end)}
  end

  @doc """
  Makes `namespace` the one this user last worked in, and the one the shell
  shows wherever an address names no scope. `nil` keeps the previous one.

  Only a namespace the controller lists is kept or shown: the value comes from
  the address bar, and the rail must never point at a scope that answers
  nothing.
  """
  def keep_namespace(socket, namespace) do
    %{last_namespace: last, shell_namespaces: known, scoped_namespace: scoped} = socket.assigns

    if namespace != last and namespace in known,
      do: FlezhaUi.Accounts.remember_namespace(socket.assigns.current_scope.user, namespace)

    last = if namespace in known, do: namespace, else: last

    Phoenix.Component.assign(socket,
      last_namespace: last,
      shell_namespace: scoped || if(last in known, do: last)
    )
  end

  @doc """
  Where `/` lands for a user: the Home of the namespace they last worked in,
  then the first reachable namespace in sorted order, then the namespace list.
  """
  def landing(last_namespace, reachable) do
    cond do
      last_namespace in reachable -> scoped_path(last_namespace, nil)
      reachable != [] -> scoped_path(reachable |> Enum.sort() |> hd(), nil)
      true -> ~p"/namespaces"
    end
  end

  @doc """
  The namespaces a plain controller page's picker offers: no socket keeps them
  for it, so they are read once for the render.
  """
  def dead_namespaces(assigns) do
    assigns[:current_scope]
    |> FlezhaUi.Accounts.Scope.flezha_token()
    |> NodeManager.scoped_namespaces()
    |> elem(0)
  end

  @doc "The namespace a plain controller page's rail shows: the one last worked in."
  def dead_namespace(assigns) do
    case assigns[:current_scope] do
      %{user: %{last_namespace: last}} when is_binary(last) -> last
      _none -> nil
    end
  end

  # A path as `{namespace, the segments below it}`, or `{nil, its segments}`
  # when it carries no scope. Every question the shell asks about a route is
  # asked of this one reading, and asked in segments so `/relays` cannot be
  # read as a prefix of `/relaysomething`.
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
  """
  def scoped_title(base, nil), do: base
  def scoped_title(base, namespace), do: "#{base} · #{namespace}"

  @doc """
  Where the namespace switcher goes when `namespace` is chosen from `current`.

  From a namespace-scoped screen, the same screen kind under the new scope —
  including from one relay, whose id means nothing under the new namespace,
  so its relays are as close as the screen kind survives. From a Problems or
  Platform screen, or from an all-namespaces form, the namespace's Home.
  """
  def scope_target(current, namespace) do
    case split_scope(current) do
      {scope, [collection | _below]}
      when is_binary(scope) and collection in ~w(relays plugins schedules) ->
        scoped_path(namespace, collection)

      _otherwise ->
        scoped_path(namespace, nil)
    end
  end

  @doc """
  The crumb trail for a path deeper than a space's destinations, as
  `%{label:, path:}` from the namespace down. The last crumb carries no path:
  it is the page being read. A destination itself has no trail.

      iex> FlezhaUiWeb.Layouts.breadcrumbs("/namespaces/default/relays/orders/state")
      [
        %{label: "default", path: "/namespaces/default"},
        %{label: "Relays", path: "/namespaces/default/relays"},
        %{label: "orders", path: "/namespaces/default/relays/orders"},
        %{label: "State", path: nil}
      ]
  """
  def breadcrumbs(path) do
    case segments(path) do
      ["namespaces", namespace, "relays", relay | view] ->
        base = ~p"/namespaces/#{namespace}"
        relays = base <> "/relays"
        relay_path = relays <> "/" <> relay

        trail = [
          %{label: namespace, path: base},
          %{label: "Relays", path: relays},
          %{label: relay, path: relay_path}
        ]

        case view do
          [] -> List.update_at(trail, -1, &%{&1 | path: nil})
          ["listen"] -> trail ++ [%{label: "Listen", path: nil}]
          ["state"] -> trail ++ [%{label: "State", path: nil}]
          _other -> List.update_at(trail, -1, &%{&1 | path: nil})
        end

      _destination ->
        []
    end
  end

  @doc """
  The stylebook's pre-paint theme hydration, inlined verbatim.

  Read at compile time and registered as an external resource, so editing the
  stylebook recompiles this module and the page pays no second blocking
  request for six lines of script.
  """
  def theme_hydrate, do: Phoenix.HTML.raw(@theme_hydrate)

  # ---- The pulse ----
  #
  # Every 10 s on a connected screen, the shell gathers the open problems of
  # every namespace the operator's own token reaches: a fixed number of calls
  # per namespace and none per relay. It ends with the process.

  defp start_pulse(socket) do
    if Phoenix.LiveView.connected?(socket) do
      send(self(), :shell_pulse)

      Phoenix.LiveView.attach_hook(socket, :shell_pulse, :handle_info, fn
        :shell_pulse, socket ->
          Process.send_after(self(), :shell_pulse, @pulse_every)
          {:halt, pulse(socket)}

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  @doc """
  One pulse: the open problems of every reachable namespace, read with the
  socket's own token, assigned as `:shell_pulse`:

      %{items:, checked_at:}

  Items keep the time they were first seen across pulses.
  """
  def pulse(socket) do
    token = FlezhaUi.Accounts.Scope.flezha_token(socket.assigns[:current_scope])
    previous = socket.assigns[:shell_pulse]
    now = DateTime.utc_now()

    {catalog, catalog_error} = NodeManager.ok_or_error(NodeManager.list_namespaces(token), [])
    names = catalog |> Enum.map(&to_string(&1.namespace)) |> Enum.sort()

    reads =
      for name <- names do
        {rows, rows_error} = NodeManager.ok_or_error(NodeManager.relay_rows(name, token), [])
        groups = NodeManager.partition_groups(rows, token)
        declared = NodeManager.ok_or(NodeManager.namespace_record(name, token), nil)
        quotas = NodeManager.quota_usage(name, declared && declared.quotas, token)

        %{
          namespace: name,
          rows: rows,
          faulted_groups: NodeManager.faulted_group_ids(groups),
          quotas: quotas,
          error: rows_error
        }
      end

    {verdicts, _notice} = Topology.stall(token)

    items =
      Attention.derive(%{
        namespaces: reads,
        dlq: NodeManager.ok_or(NodeManager.dlq_stats(token), []),
        breaches: NodeManager.ok_or(NodeManager.durability_breaches(token), []),
        verdicts: verdicts,
        authz: NodeManager.authz_status(token),
        skew: skew([catalog_error | Enum.map(reads, & &1.error)])
      })

    {items, _appeared, _cleared} =
      Attention.track(Attention.by_id((previous && previous.items) || []), items, now)

    Phoenix.Component.assign(socket, :shell_pulse, %{items: items, checked_at: now})
  end

  defp skew(errors) do
    Enum.find(errors, &match?({:api_missing, _module, _function, _arity}, &1))
  end

  @doc """
  The help overlay for a screen kind: what the screen is for, the glossary
  entries for the terms it marks, and the keyboard shortcuts. A native
  `<dialog>`, so Escape closes it and focus returns to its opener.
  """
  attr :screen, :atom, default: nil

  def help_overlay(assigns) do
    assigns = assign(assigns, :help, Glossary.screen(assigns.screen))

    ~H"""
    <dialog
      id="help-overlay"
      class="fui-dialog-panel fui-dialog-panel--form"
      data-testid="help-overlay"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="help-title"
    >
      <div class="fui-dialog-head">
        <h2 id="help-title" class="fui-dialog-title">Help</h2>
        <form method="dialog">
          <button class="fui-iconbtn" aria-label="Close help" data-testid="help-close">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </form>
      </div>
      <div class="fui-dialog-body">
        <p :if={@help} data-testid="help-purpose">{@help.purpose}</p>
        <dl :if={@help && @help.terms != []} class="fui-glossary" data-testid="help-terms">
          <div :for={term <- @help.terms} data-testid={"help-term-#{term.key}"}>
            <dt>{term.name}</dt>
            <dd>{term.definition}</dd>
          </div>
        </dl>
        <div>
          <h3 class="fui-eyebrow mb-2">Keyboard</h3>
          <dl class="fui-shortcuts" data-testid="help-shortcuts">
            <%= for {keys, what} <- Glossary.shortcuts() do %>
              <dt>
                <.kbd :for={key <- keys}>{key}</.kbd>
              </dt>
              <dd>{what}</dd>
            <% end %>
          </dl>
        </div>
      </div>
    </dialog>
    """
  end
end
