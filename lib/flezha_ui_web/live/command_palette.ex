defmodule FlezhaUiWeb.CommandPalette do
  @moduledoc """
  Reaching a known object by typing its name, from any screen.

  Mounted once by the shell, so every screen has it and no screen implements
  it. Its destinations are the ones the sidebar already offers plus the
  namespaces and operatives the bound token can reach — nothing the palette
  can reach is unreachable by clicking.

  The operative index is the expensive part, so it is read on the first open
  rather than on mount: a screen the operator never opens the palette on pays
  nothing for it. Once read it is held on the component and dropped again by
  `invalidate/1`, which `FlezhaUiWeb.Live.Refresh` calls on the same lifecycle
  events the screens themselves refresh on.
  """

  use FlezhaUiWeb, :live_component

  alias FlezhaUi.Service.NodeManager

  @id "command-palette"
  @limit 20

  @doc """
  Drops the cached operative index, so the next open reads it again.

  A no-op before the socket is connected: there is no component to update on a
  dead render, and nothing has been cached there to go stale.
  """
  def invalidate(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.LiveView.send_update(__MODULE__, id: @id, operatives: nil)
    end

    socket
  end

  @doc "The id the shell mounts this under, and `invalidate/1` addresses."
  def id, do: @id

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open, fn -> false end)
     |> assign_new(:query, fn -> "" end)
     |> assign_new(:operatives, fn -> nil end)}
  end

  @impl true
  def handle_event("open", _params, socket) do
    {:noreply, socket |> load_operatives() |> assign(open: true, query: "")}
  end

  @impl true
  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, open: false)}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, assign(socket, query: query)}
  end

  # One registry dump per reachable namespace, the same read the Fleet screen
  # makes — never one call per operative.
  defp load_operatives(%{assigns: %{operatives: rows}} = socket) when is_list(rows), do: socket

  defp load_operatives(socket) do
    rows =
      Enum.flat_map(socket.assigns.namespaces, fn namespace ->
        namespace
        |> NodeManager.namespace_rows()
        |> Enum.map(fn row ->
          %{id: to_string(row.id), namespace: namespace, health: row.health}
        end)
      end)

    assign(socket, operatives: rows)
  end

  # The destinations a typed string names. Screens come from the same list the
  # sidebar renders, so the palette cannot offer a screen the rail does not —
  # or miss one it does.
  defp matches(assigns) do
    needle = assigns.query |> to_string() |> String.trim() |> String.downcase()

    (screens(assigns.scope) ++ namespaces(assigns.namespaces) ++ operatives(assigns.operatives))
    |> Enum.filter(&String.contains?(String.downcase(&1.label), needle))
  end

  defp screens(scope) do
    for section <- FlezhaUiWeb.Layouts.nav_sections(scope), entry <- section.entries do
      entry("screen", entry.label, entry.path)
    end
  end

  defp namespaces(names) do
    for name <- names || [], do: entry("namespace", name, ~p"/namespaces/#{name}")
  end

  defp operatives(nil), do: []

  defp operatives(rows) do
    for row <- rows do
      entry("operative", row.id, ~p"/namespaces/#{row.namespace}/operatives/#{row.id}",
        detail: "#{row.namespace} · #{row.health}"
      )
    end
  end

  # An operative is the one destination whose name is not enough on its own —
  # an id says nothing about where it runs or how it is faring.
  defp entry(kind, label, path, opts \\ []) do
    %{kind: kind, label: label, path: path, detail: opts[:detail]}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:limit, @limit)
      |> assign(:found, if(assigns.open, do: matches(assigns), else: []))

    ~H"""
    <div id={@id} phx-hook="FlzPalette" phx-target={@myself} data-open={to_string(@open)}>
      <div :if={@open} class="flz-modal flz-palette">
        <div
          class="flz-modal-surface max-w-xl"
          data-testid="command-palette"
          phx-click-away="close"
          phx-target={@myself}
        >
          <form phx-change="search" phx-target={@myself} autocomplete="off">
            <input
              type="text"
              name="q"
              value={@query}
              class="flz-palette-input"
              placeholder="Operative id, namespace, or screen"
              data-testid="command-palette-input"
              phx-debounce="80"
            />
          </form>

          <p :if={@found == []} class="flz-empty" data-testid="command-palette-empty">
            Nothing matches “{@query}”.
          </p>

          <ul :if={@found != []} class="flz-palette-list" data-testid="command-palette-results">
            <li :for={match <- Enum.take(@found, @limit)}>
              <.link
                navigate={match.path}
                class="flz-palette-option"
                data-testid={"command-palette-#{match.kind}-#{match.label}"}
              >
                <span class="flex items-center gap-2 truncate">
                  <span class="flz-badge">{match.kind}</span>
                  <span class="flz-num truncate">{match.label}</span>
                </span>
                <span :if={match.detail} class="text-xs text-th-muted flz-num shrink-0">
                  {match.detail}
                </span>
              </.link>
            </li>
          </ul>

          <p
            :if={length(@found) > @limit}
            class="px-4 py-2 text-xs text-th-muted"
            data-testid="command-palette-truncated"
          >
            {length(@found) - @limit} more match — keep typing to narrow them.
          </p>
        </div>
      </div>
    </div>
    """
  end
end
