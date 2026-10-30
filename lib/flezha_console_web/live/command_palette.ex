defmodule FlezhaConsoleWeb.CommandPalette do
  @moduledoc """
  Reaching a known object by typing its name, and acting on it, from any
  screen.

  Mounted once by the shell, so every screen has it and no screen implements
  it. Its destinations are the rail's own (`FlezhaConsoleWeb.Layouts.nav_sections/1`)
  plus the namespaces, relays, factories and schedules the bound token can reach —
  nothing the palette reaches is unreachable by clicking.

  It also offers actions on a named object, as the operator's operations
  allow: stop a relay, diagnose it, listen to its output, run a schedule now,
  open the open problems. An action that changes state lands on its own
  screen with that screen's confirmation open, and never acts on the
  keystroke alone.

  Relays are searched on the controller as the operator types: a namespace
  may run thousands, so each query reads at most 20 matches per reachable
  namespace rather than holding every relay. The factory and schedule index is
  read on the first open rather than on mount: a screen the operator never
  opens the palette on pays nothing for it. Once read it is held on the
  component and dropped again by `invalidate/1`, which
  `FlezhaConsoleWeb.Live.Refresh` calls on the same lifecycle events the
  screens themselves refresh on.
  """

  use FlezhaConsoleWeb, :live_component

  alias FlezhaConsole.Service.NodeManager

  @id "command-palette"
  @limit 20

  @doc """
  Drops the cached index, so the next open reads it again.

  A no-op before the socket is connected: there is no component to update on a
  dead render, and nothing has been cached there to go stale.
  """
  def invalidate(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.LiveView.send_update(__MODULE__, id: @id, relays: nil)
    end

    socket
  end

  @doc "The id the shell mounts this under, and `invalidate/1` addresses."
  def id, do: @id

  @doc "Opens the palette from a control, for a screen without a keyboard."
  def open, do: JS.push("open", target: "##{@id}")

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open, fn -> false end)
     |> assign_new(:query, fn -> "" end)
     |> assign_new(:relays, fn -> nil end)
     |> assign_new(:relays_unread, fn -> 0 end)
     |> assign_new(:schedules, fn -> [] end)
     |> assign_new(:factories, fn -> [] end)
     |> assign_new(:operations, fn -> nil end)}
  end

  @impl true
  def handle_event("open", _params, socket) do
    {:noreply, socket |> load_index() |> assign(open: true, query: "") |> search_relays()}
  end

  @impl true
  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, open: false)}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) when is_binary(query) do
    {:noreply, socket |> assign(query: query) |> search_relays()}
  end

  # The relays matching the query, at most @limit per reachable namespace: a
  # search the controller makes. An action's verb is not part of a relay's
  # name, so "stop ord" searches "ord".
  defp search_relays(socket) do
    %{namespaces: namespaces, token: token, query: query} = socket.assigns

    reads =
      for namespace <- namespaces || [],
          do: {namespace, NodeManager.search_relays(namespace, token, relay_term(query), @limit)}

    rows =
      for {namespace, read} <- reads,
          row <- NodeManager.ok_or(read, []),
          do: %{id: to_string(row.id), namespace: namespace, health: row.health}

    matching = Enum.sum(for {_namespace, {:ok, %{total: total}}} <- reads, do: total)
    assign(socket, relays: rows, relays_unread: matching - length(rows))
  end

  @verbs ~w(stop diagnose listen)

  defp relay_term(query) do
    words = query |> to_string() |> String.trim() |> String.split(~r/\s+/, trim: true)

    case words do
      [verb | rest] -> if(String.downcase(verb) in @verbs, do: rest, else: words)
      [] -> []
    end
    |> Enum.reject(&(String.downcase(&1) in ["to", "output"]))
    |> Enum.join(" ")
  end

  # One factory catalog read per reachable namespace, the read the factories
  # screen makes, and one schedule listing — never one call per factory.
  defp load_index(%{assigns: %{relays: rows}} = socket) when is_list(rows), do: socket

  defp load_index(socket) do
    %{namespaces: namespaces, token: token} = socket.assigns

    factories =
      for namespace <- namespaces,
          factory <- namespace |> NodeManager.factory_catalog(token) |> NodeManager.ok_or([]),
          do: %{id: factory.id, namespace: namespace}

    schedules =
      token
      |> NodeManager.schedule_list()
      |> NodeManager.ok_or([])
      |> Enum.map(&to_string(&1.name))

    assign(socket, factories: factories, schedules: schedules)
  end

  # The destinations and actions a typed string names. Screens come from the
  # same list the rail renders, so the palette cannot offer a screen the rail
  # does not — or miss one it does.
  defp matches(assigns) do
    needle = assigns.query |> to_string() |> String.trim() |> String.downcase()

    (screens(assigns.scope) ++
       namespaces(assigns.namespaces) ++
       relays(assigns.relays) ++
       factories(assigns.factories) ++
       actions(assigns))
    |> Enum.filter(
      &(&1.operation == nil or NodeManager.granted?(assigns.operations, &1.operation))
    )
    |> Enum.filter(&String.contains?(String.downcase(&1.label), needle))
  end

  defp screens(scope) do
    for section <- FlezhaConsoleWeb.Layouts.nav_sections(scope),
        dest <- section.entries,
        do: entry("screen", dest.label, dest.path)
  end

  defp namespaces(names) do
    for name <- names || [], do: entry("namespace", name, ~p"/namespaces/#{name}")
  end

  defp relays(nil), do: []

  defp relays(rows) do
    for row <- rows do
      entry("relay", row.id, ~p"/namespaces/#{row.namespace}/relays/#{row.id}",
        detail: "#{row.namespace} · #{Words.text(:health, row.health)}"
      )
    end
  end

  defp factories(factories) do
    for factory <- factories do
      entry("factory", factory.id, ~p"/namespaces/#{factory.namespace}/factories/#{factory.id}",
        detail: factory.namespace
      )
    end
  end

  # Each lands on the screen that owns the action, with that screen's own
  # confirmation open where the action changes state.
  defp actions(assigns) do
    relay_actions =
      for row <- assigns.relays || [] do
        base = ~p"/namespaces/#{row.namespace}/relays/#{row.id}"

        [
          entry("action", "Stop #{row.id}", base <> "?do=stop",
            detail: row.namespace,
            operation: "Relay.stop"
          ),
          entry("action", "Diagnose #{row.id}", base <> "?do=diagnose",
            detail: row.namespace,
            operation: "Relay.diagnose"
          ),
          entry("action", "Listen to #{row.id} output", base <> "/listen",
            detail: row.namespace,
            operation: "Relay.listen"
          )
        ]
      end

    schedule_actions =
      for name <- assigns.schedules do
        entry("action", "Run #{name} now", ~p"/schedules?#{[run: name]}",
          detail: "schedule",
          operation: "Schedule.run"
        )
      end

    [entry("action", "Open open problems", ~p"/problems") | List.flatten(relay_actions)] ++
      schedule_actions
  end

  # A relay is the one destination whose name is not enough on its own —
  # an id says nothing about where it runs or how it is faring.
  defp entry(kind, label, path, opts \\ []) do
    %{
      kind: kind,
      label: label,
      path: path,
      detail: opts[:detail],
      operation: opts[:operation]
    }
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:limit, @limit)
      |> assign(:found, if(assigns.open, do: matches(assigns), else: []))

    # Relays the search matched past those it read are matches too.
    assigns = assign(assigns, :more, length(assigns.found) - @limit + assigns.relays_unread)

    ~H"""
    <div id={@id} phx-hook="FlzPalette" phx-target={@myself} data-open={to_string(@open)}>
      <div :if={@open} class="fcon-dialog fcon-palette">
        <div class="fcon-scrim"></div>
        <div
          id="command-palette-panel"
          class="fcon-dialog-panel"
          phx-hook="FlzFocus"
          role="dialog"
          aria-modal="true"
          aria-label="Search or run a command"
          data-testid="command-palette"
          phx-click-away="close"
          phx-target={@myself}
        >
          <form
            id="command-palette-search"
            phx-change="search"
            phx-target={@myself}
            autocomplete="off"
            data-testid="command-palette-search"
          >
            <input
              type="text"
              name="q"
              value={@query}
              class="fcon-palette-input"
              placeholder="Relay, factory, namespace, screen or action — try “stop” or “diagnose”"
              aria-label="Search or run a command"
              data-testid="command-palette-input"
              phx-debounce="80"
            />
            <%!-- A phone has no Escape key and no outside to tap. --%>
            <button
              type="button"
              class="fcon-palette-cancel"
              phx-click="close"
              phx-target={@myself}
              data-testid="command-palette-close"
            >
              Cancel
            </button>
          </form>

          <p :if={@found == []} class="fcon-palette-note" data-testid="command-palette-empty">
            Nothing matches “{@query}”: no relay, factory, namespace, screen or action of that name.
          </p>

          <ul :if={@found != []} class="fcon-palette-list" data-testid="command-palette-results">
            <li :for={match <- Enum.take(@found, @limit)}>
              <.link
                navigate={match.path}
                class="fcon-palette-option"
                data-testid={"command-palette-#{match.kind}-#{match.label}"}
              >
                <span class="flex items-center gap-2 min-w-0">
                  <.chip>{match.kind}</.chip>
                  <span class="truncate">{match.label}</span>
                </span>
                <span :if={match.detail} class="fcon-palette-meta">{match.detail}</span>
              </.link>
            </li>
          </ul>

          <p :if={@more > 0} class="fcon-palette-note" data-testid="command-palette-truncated">
            {@more} more match — keep typing to narrow them.
          </p>
        </div>
      </div>
    </div>
    """
  end
end
