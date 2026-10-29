defmodule FlezhaConsoleWeb.Layouts do
  @moduledoc """
  The console's shell — the rail beside a topbar — and the derivation of where
  the operator is that every screen shares.

  The rail lists the namespace's own screens, then what needs attention, the
  platform and its monitoring; the topbar holds the connection, the namespace
  picker, the screen's liveness, the bound identity, help, the theme toggle
  and the account menu. Below desk width the rail is a drawer, and a phone
  shows the shortcut destinations as a bar along the bottom edge.

  "root" is the document skeleton; "app" wraps every LiveView and the plain
  settings page; "auth" is the signed-out canvas.
  """
  use FlezhaConsoleWeb, :html

  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.Attention
  alias FlezhaConsoleWeb.Glossary
  alias FlezhaConsoleWeb.Topology

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

  @doc """
  How long a page's websocket may take to answer before Phoenix falls back to
  long polling, for `app.js` to read; nothing when `ms` is nil, and the page
  keeps its websocket however slowly it answers.
  """
  attr :ms, :integer, required: true

  def longpoll_fallback(assigns) do
    ~H"""
    <meta :if={@ms} name="longpoll-fallback-ms" content={@ms} />
    """
  end

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

  Every relay across namespaces is the Relays screen's own "All namespaces"
  switch, not a destination of its own.
  """
  def nav_sections(namespace) do
    [
      %{heading: "Namespace", scope: namespace, entries: scoped_entries(namespace)},
      %{
        heading: "Attention",
        scope: nil,
        entries: [problems(), entry(~p"/dlq", "hero-inbox-stack", "Dead-letter")]
      },
      %{
        heading: "Platform",
        scope: nil,
        entries: [
          entry(~p"/namespaces", "hero-rectangle-stack", "Namespaces"),
          cluster(),
          entry(~p"/controller", "hero-server", "Controller")
        ]
      },
      %{
        heading: "Monitoring",
        scope: nil,
        entries: [
          entry(~p"/observability", "hero-signal", "Observability"),
          entry(~p"/logs", "hero-document-text", "Logs")
        ]
      }
    ]
  end

  defp scoped_entries(nil), do: []

  defp scoped_entries(namespace) do
    [
      home(scoped_path(namespace, nil)),
      relays(scoped_path(namespace, "relays")),
      entry(scoped_path(namespace, "factories"), "hero-cube", "Factories"),
      entry(scoped_path(namespace, "plugins"), "hero-puzzle-piece", "Plugins"),
      entry(scoped_path(namespace, "schedules"), "hero-clock", "Schedules")
    ]
  end

  @doc """
  The places `g` then a letter reaches, by their letter; each is in the rail
  too, and a phone shows them as its bottom bar. With no namespace in scope,
  Home and Relays fall back to the namespaces and to every relay.
  """
  def shortcuts(namespace) do
    [
      {"h", home((namespace && scoped_path(namespace, nil)) || ~p"/namespaces")},
      {"r", relays((namespace && scoped_path(namespace, "relays")) || ~p"/relays")},
      {"p", problems()},
      {"c", cluster()}
    ]
  end

  defp home(path), do: entry(path, "hero-home", "Home")
  defp relays(path), do: entry(path, "hero-cpu-chip", "Relays")
  defp problems, do: entry(~p"/problems", "hero-exclamation-triangle", "Problems", :problems)
  defp cluster, do: entry(~p"/cluster", "hero-server-stack", "Cluster")

  defp entry(path, icon, label, count \\ nil),
    do: %{path: path, icon: icon, label: label, count: count}

  @doc """
  Whether a navigation destination is the page being shown.

  An entry owns the subtree below it, measured from its own scope: a
  namespace's Home sits at the root of its scope, so it is an exact match, and
  Relays still owns the relay below it. Entries in different scopes never
  match, so `/namespaces/x` never marks a platform entry such as `/namespaces`.
  """
  def nav_current?(current, path) do
    case {split_scope(current), split_scope(path)} do
      {{scope, below}, {scope, []}} -> below == []
      {{scope, below}, {scope, entry}} -> List.starts_with?(below, entry)
      _differing -> false
    end
  end

  @screens Map.new(
             ~w(relays factories plugins schedules problems dlq namespaces cluster controller observability logs)a,
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
      ["namespaces", _ns, "factories", _id] -> :factory
      ["namespaces", _ns, kind] when is_map_key(@screens, kind) -> @screens[kind]
      [kind] when is_map_key(@screens, kind) -> @screens[kind]
      ["logs", _kind] -> :logs
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
    for {view, label} <- [live: "Live", listen: "Listen", state: "State"] do
      %{
        label: label,
        path: relay_path(namespace, relay_id, view),
        current?: view == current,
        testid: "relay-tab-#{view}"
      }
    end
  end

  @doc "One of a relay's three views by name: `:live`, `:listen` or `:state`."
  def relay_path(namespace, relay_id, :live), do: ~p"/namespaces/#{namespace}/relays/#{relay_id}"

  def relay_path(namespace, relay_id, :listen),
    do: ~p"/namespaces/#{namespace}/relays/#{relay_id}/listen"

  def relay_path(namespace, relay_id, :state),
    do: ~p"/namespaces/#{namespace}/relays/#{relay_id}/state"

  @doc """
  A partition member's way to the other partitions of its group, each opened
  on the same view; nothing for a relay that is no partition member.
  `members` are `NodeManager.partition_members/2`'s rows.
  """
  attr :ns, :string, required: true
  attr :relay_id, :string, required: true
  attr :view, :atom, required: true, values: [:live, :listen, :state]
  attr :members, :list, required: true

  def partition_menu(assigns) do
    assigns = assign(assigns, :current, NodeManager.relay_row(assigns.members, assigns.relay_id))

    ~H"""
    <.popover
      :if={@current}
      id="relay-partition-menu"
      testid="partition-menu"
      label={"Partition p#{@current.partition.index} of #{@current.partition.count}"}
      align="end"
      trigger_class="flz-button flz-button--secondary flz-button--md"
    >
      <:trigger>
        Partition p{@current.partition.index} of {@current.partition.count}
        <.icon name="hero-chevron-down-micro" />
      </:trigger>
      <.link
        :for={member <- @members}
        navigate={relay_path(@ns, member.id, @view)}
        role="menuitemradio"
        aria-checked={to_string(member == @current)}
        data-testid={"partition-menu-#{member.id}"}
        data-fcon-pop-item
        class="fcon-menu-item fcon-num"
      >
        p{member.partition.index} · keys {Format.key_range(member.partition.range)} · {Words.text(
          :health,
          member.health
        )}
        <.icon :if={member == @current} name="hero-check-micro" class="ml-auto" />
      </.link>
    </.popover>
    """
  end

  @doc """
  A namespace's screen, by the collection segment that names it.

  Written out per collection because a verified route is checked against the
  router, and a path built from two interpolated segments matches none of them.
  """
  def scoped_path(namespace, nil), do: ~p"/namespaces/#{namespace}"
  def scoped_path(namespace, "relays"), do: ~p"/namespaces/#{namespace}/relays"
  def scoped_path(namespace, "factories"), do: ~p"/namespaces/#{namespace}/factories"
  def scoped_path(namespace, "plugins"), do: ~p"/namespaces/#{namespace}/plugins"
  def scoped_path(namespace, "schedules"), do: ~p"/namespaces/#{namespace}/schedules"

  @doc """
  The switch between a scoped listing and its all-namespaces twin, named by
  their collection segment: the namespace the shell shows, or every one.
  """
  attr :collection, :string, required: true, values: ~w(relays factories plugins schedules)
  attr :shell_namespace, :string, default: nil
  attr :scoped_namespace, :string, default: nil

  def scope_switch(assigns) do
    ~H"""
    <.segmented label="Scope" testid="scope-switch">
      <:option
        :if={@shell_namespace}
        patch={scoped_path(@shell_namespace, @collection)}
        current={@scoped_namespace != nil}
        testid="scope-namespace"
      >
        {@shell_namespace}
      </:option>
      <:option
        patch={"/" <> @collection}
        current={is_nil(@scoped_namespace)}
        testid="scope-all"
      >
        All namespaces
      </:option>
    </.segmented>
    """
  end

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

  On a connected socket it also starts the shell's pulse (`pulse_read/1`). The
  chip's namespaces are resolved once per mount: they change rarely, and a
  screen ticking every two seconds would otherwise pay a controller round-trip
  per tick for a control it is not using.
  """
  def on_mount(:current_path, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign_new(:shell_namespaces, fn ->
        socket.assigns[:current_scope]
        |> FlezhaConsole.Accounts.Scope.flezha_token()
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
      do: FlezhaConsole.Accounts.remember_namespace(socket.assigns.current_scope.user, namespace)

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
    |> FlezhaConsole.Accounts.Scope.flezha_token()
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

      iex> FlezhaConsoleWeb.Layouts.scoped_namespace("/namespaces/default/plugins")
      "default"
      iex> FlezhaConsoleWeb.Layouts.scoped_namespace("/namespaces")
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
      when is_binary(scope) and collection in ~w(relays factories plugins schedules) ->
        scoped_path(namespace, collection)

      _otherwise ->
        scoped_path(namespace, nil)
    end
  end

  @doc """
  The crumb trail for a path deeper than a space's destinations, as
  `%{label:, path:}` from the namespace down. The last crumb carries no path:
  it is the page being read. A destination itself has no trail.

      iex> FlezhaConsoleWeb.Layouts.breadcrumbs("/namespaces/default/relays/orders/state")
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

        # The path carries ids percent-encoded (`demo%23p0`); a crumb names them.
        trail = [
          %{label: URI.decode(namespace), path: base},
          %{label: "Relays", path: relays},
          %{label: URI.decode(relay), path: relay_path}
        ]

        case view do
          [] -> List.update_at(trail, -1, &%{&1 | path: nil})
          ["listen"] -> trail ++ [%{label: "Listen", path: nil}]
          ["state"] -> trail ++ [%{label: "State", path: nil}]
          _other -> List.update_at(trail, -1, &%{&1 | path: nil})
        end

      ["namespaces", namespace, "factories", factory] ->
        base = ~p"/namespaces/#{namespace}"

        [
          %{label: URI.decode(namespace), path: base},
          %{label: "Factories", path: base <> "/factories"},
          %{label: URI.decode(factory), path: nil}
        ]

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

  @doc """
  The theme toggle, drawn as flezha.com draws it: a sun in dark (switch to
  light), a moon in light. The stylebook's `bindThemeToggles/0` binds it.
  """
  attr :testid, :string, default: "theme-toggle"
  attr :rest, :global

  def theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="flz-chrome-icon-btn"
      data-flz-theme-toggle
      aria-label="Toggle color theme"
      title="Toggle light/dark mode"
      data-testid={@testid}
      {@rest}
    >
      <svg
        class="flz-theme-sun"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        aria-hidden="true"
      >
        <circle cx="12" cy="12" r="4"></circle>
        <path d="M12 2v2m0 16v2M4.9 4.9l1.4 1.4m11.4 11.4l1.4 1.4M2 12h2m16 0h2M4.9 19.1l1.4-1.4m11.4-11.4l1.4-1.4">
        </path>
      </svg>
      <svg
        class="flz-theme-moon"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"></path>
      </svg>
    </button>
    """
  end

  # What opens and closes the drawer the rail becomes below desk width.
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  defp nav_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class={@class}
      data-fcon-nav-toggle
      aria-controls="shell-nav"
      aria-expanded="false"
      phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # The flezha principal the console's token is bound to.
  attr :status, :map, required: true, doc: "a `NodeManager.authz_status/1` map"
  attr :class, :any, default: nil
  attr :rest, :global

  defp principal(assigns) do
    ~H"""
    <span
      class={["flz-num flex min-w-0 items-center gap-1.5", @class]}
      title={"flezha principal #{@status.principal}"}
      {@rest}
    >
      <.icon name="hero-key" class="w-3.5 h-3.5 shrink-0" />
      <span class="truncate">
        {@status.principal}<span :if={@status.namespace}>/{@status.namespace}</span>
        <span :if={@status.role}>({@status.role})</span>
      </span>
    </span>
    """
  end

  # How many problems are open, in the worst one's tone; nothing when clear.
  attr :problems, :list, default: nil
  attr :class, :string, default: nil
  attr :testid, :string, required: true

  defp problems_count(assigns) do
    ~H"""
    <span
      :if={@problems not in [nil, []]}
      class={["fcon-count fcon-count--#{Attention.worst(@problems)}", @class]}
      data-testid={@testid}
      data-tone={Attention.worst(@problems)}
    >
      {length(@problems)}
    </span>
    """
  end

  # ---- The pulse ----
  #
  # Every 10 s on a connected screen, the shell gathers the open problems of
  # every namespace the operator's own token reaches: a fixed number of calls
  # per namespace and none per relay. The calls run in a task, one pulse at a
  # time, so a slow controller never holds the screen. It ends with the process.

  defp start_pulse(socket) do
    if Phoenix.LiveView.connected?(socket) do
      send(self(), :shell_pulse)

      socket
      |> Phoenix.LiveView.attach_hook(:shell_pulse, :handle_info, fn
        :shell_pulse, socket ->
          Process.send_after(self(), :shell_pulse, @pulse_every)

          {:halt,
           FlezhaConsoleWeb.Live.Refresh.start_once(
             socket,
             :pulse_reading,
             :shell_pulse,
             pulse_read(socket)
           )}

        _message, socket ->
          {:cont, socket}
      end)
      |> FlezhaConsoleWeb.Live.Refresh.on_answer(:shell_pulse, :pulse_reading, &pulse_apply/2)
    else
      socket
    end
  end

  @doc """
  One pulse's reads, as a function to run off the screen's process: the
  namespaces the socket's token reaches, each one's relay rows, partition
  groups and quotas, and the fleet-wide stall verdicts, durability breaches,
  dead-letter stats, authorization posture and connected controllers.
  `pulse_apply/2` takes its answer.
  """
  def pulse_read(socket) do
    token = FlezhaConsole.Accounts.Scope.flezha_token(socket.assigns[:current_scope])
    fn -> pulse_calls(token) end
  end

  defp pulse_calls(token) do
    read_at = DateTime.utc_now()
    listed = NodeManager.list_namespaces(token)
    {catalog, catalog_error} = NodeManager.ok_or_error(listed, [])
    names = catalog |> Enum.map(&to_string(&1.namespace)) |> Enum.sort()

    reads =
      for name <- names do
        read_rows = NodeManager.relay_rows(name, token)
        {rows, rows_error} = NodeManager.ok_or_error(read_rows, [])
        groups = NodeManager.partition_groups(rows, token)
        declared = NodeManager.ok_or(NodeManager.namespace_record(name, token), nil)
        quotas = NodeManager.quota_usage(name, declared && declared.quotas, token)

        %{
          namespace: name,
          rows: rows,
          faulted_groups: NodeManager.faulted_group_ids(groups),
          quotas: quotas,
          serving: NodeManager.serving_counts(name, Attention.waiting_factories(rows), token),
          error: rows_error,
          unreachable: NodeManager.unreachable([read_rows | quotas])
        }
      end

    {verdicts, _notice} = Topology.stall(token)
    breaches = NodeManager.durability_breaches(token)
    dlq = FlezhaConsole.DeadLetters.stats(token)
    controllers = NodeManager.controllers(token)

    %{
      read_at: read_at,
      catalog_error: catalog_error,
      reads: reads,
      verdicts: verdicts,
      breaches: NodeManager.ok_or(breaches, []),
      dlq: NodeManager.ok_or(dlq, []),
      authz: NodeManager.authz_status(token),
      controllers: NodeManager.ok_or(controllers, []),
      unreachable: NodeManager.unreachable([listed, breaches, dlq, controllers | reads])
    }
  end

  @doc """
  Assigns one pulse's answer as `:shell_pulse`:

      %{items:, checked_at:, error:, fleet:, serving:, controllers:, unreachable:}

  Items keep the time they were first seen across pulses. `error` is why the
  namespaces could not be listed, so no problem list stands for an all-clear.

  `fleet` counts what the pulse's reads already answer: the relays' `health`
  across every reachable namespace as `NodeManager.health_counts/1` pairs, and
  the durability `breaches`. `serving` is each namespace's runner counts per
  waiting factory. `controllers` are `NodeManager.controllers/1`'s rows, none
  when they could not be read, and `unreachable` the controllers its reads
  lack. A pulse that died keeps the last one.
  """
  def pulse_apply(socket, {:exit, _reason}), do: socket

  def pulse_apply(socket, {:ok, pulse}) do
    previous = socket.assigns[:shell_pulse]

    known = (previous && previous[:serving]) || %{}

    reads =
      Enum.map(pulse.reads, fn read ->
        %{read | serving: Attention.keep_serving(read.serving, known[read.namespace], read.rows)}
      end)

    items =
      Attention.derive(%{
        namespaces: reads,
        dlq: pulse.dlq,
        breaches: pulse.breaches,
        verdicts: pulse.verdicts,
        authz: pulse.authz,
        skew: skew([pulse.catalog_error | Enum.map(pulse.reads, & &1.error)])
      })

    {items, _appeared, _cleared} =
      Attention.track(Attention.by_id((previous && previous.items) || []), items, pulse.read_at)

    Phoenix.Component.assign(socket, :shell_pulse, %{
      items: items,
      checked_at: pulse.read_at,
      error: pulse.catalog_error,
      fleet: %{
        health: pulse.reads |> Enum.flat_map(& &1.rows) |> NodeManager.health_counts(),
        breaches: length(pulse.breaches)
      },
      serving: Map.new(reads, &{&1.namespace, &1.serving}),
      controllers: pulse.controllers,
      unreachable: pulse.unreachable
    })
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
      class="fcon-dialog-panel fcon-dialog-panel--form"
      data-testid="help-overlay"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="help-title"
    >
      <div class="fcon-dialog-head">
        <h2 id="help-title" class="fcon-dialog-title">Help</h2>
        <form method="dialog">
          <button class="fcon-iconbtn" aria-label="Close help" data-testid="help-close">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </form>
      </div>
      <div class="fcon-dialog-body">
        <p :if={@help} data-testid="help-purpose">{@help.purpose}</p>
        <dl :if={@help && @help.terms != []} class="fcon-glossary" data-testid="help-terms">
          <div :for={term <- @help.terms} data-testid={"help-term-#{term.key}"}>
            <dt>{term.name}</dt>
            <dd>{term.definition}</dd>
          </div>
        </dl>
        <div>
          <h3 class="fcon-eyebrow mb-2">Keyboard</h3>
          <dl class="fcon-shortcuts" data-testid="help-shortcuts">
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
