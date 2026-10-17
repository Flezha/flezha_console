defmodule FlezhaUiWeb.Live.Sections do
  @moduledoc """
  Which of a long screen's panels are open, and how many rows each of its
  listings shows.

  A screen carrying more than four panels opens on what the operator came for
  and folds the rest away. Which ones start open is the screen's own decision,
  declared once where the screen is defined:

      use FlezhaUiWeb.Live.Sections,
        open: %{"journal" => false, "inbox" => false}

      def mount(_params, _session, socket) do
        {:ok, socket |> sections_init() |> load()}
      end

  A section whose content is read only when someone looks at it overrides
  `section_opened/2`, called with the socket and the key each time a section
  opens — by a click or by the hook restoring it. A section that holds
  something while open, such as a live feed, also overrides
  `section_closed/2`, called the same way each time a section folds.

  The state is held here rather than in the browser because LiveView re-renders
  from the server: an attribute the client flipped would be patched back on the
  next tick, and these screens tick. The viewer's own last choice is restored
  over the declared default by the `FlzSection` hook, which is also what
  persists it — so a browser that refuses to store anything leaves the screen
  on its declared defaults rather than stuck shut.
  """

  @doc false
  defmacro __using__(opts) do
    open = Keyword.fetch!(opts, :open)

    quote do
      @sections_open unquote(open)

      @doc false
      def sections_init(socket), do: Phoenix.Component.assign(socket, :sections, @sections_open)

      @impl Phoenix.LiveView
      def handle_event("section_toggle", %{"key" => key}, socket) do
        socket = FlezhaUiWeb.Live.Sections.toggle(socket, key)

        if socket.assigns.sections[key],
          do: {:noreply, section_opened(socket, key)},
          else: {:noreply, section_closed(socket, key)}
      end

      # Opens a section if it is folded, and brings it into view: a link to a
      # section from elsewhere on the screen.
      def handle_event("section_reveal", %{"key" => key}, socket) do
        socket =
          if socket.assigns.sections[key],
            do: socket,
            else: section_opened(FlezhaUiWeb.Live.Sections.toggle(socket, key), key)

        {:noreply, FlezhaUiWeb.CoreComponents.reveal(socket, key)}
      end

      def handle_event("section_reveal", _params, socket), do: {:noreply, socket}

      @doc false
      def section_opened(socket, _key), do: socket

      @doc false
      def section_closed(socket, _key), do: socket

      defoverridable section_opened: 2, section_closed: 2
    end
  end

  @page_size 20
  # A count, an id and the number of grown listings are bounded, so forged
  # events cannot make a screen render an unbounded listing or hold an
  # unbounded map. Ids are built from data (a relay class, a factory), so the
  # id bound is loose.
  @max_shown 10_000
  @max_id_bytes 1_024
  @max_listings 64

  @doc """
  Paging for every screen of a live session: `@paging` holds how many rows
  each listing shows, by listing id, and one `grid_more` event grows a
  listing by a page. It is held here rather than in the browser for the
  reason sections are — the screens tick, and a tick that re-reads the rows
  must not shrink a listing the operator grew.

      live_session :authenticated, on_mount: [{FlezhaUiWeb.Live.Sections, :paging}]
  """
  def on_mount(:paging, _params, _session, socket) do
    {:cont,
     socket
     |> Phoenix.Component.assign(:paging, %{})
     |> Phoenix.LiveView.attach_hook(:paging, :handle_event, &grow/3)}
  end

  # Named exactly, so a screen's own events pass through untouched.
  @events ~w(grid_more)

  defp grow(event, %{"id" => id, "shown" => shown, "step" => step}, socket)
       when event in @events and is_binary(id) and byte_size(id) <= @max_id_bytes and
              is_binary(shown) and is_binary(step) do
    with {shown, ""} <- Integer.parse(shown),
         {step, ""} <- Integer.parse(step),
         true <- shown >= 0 and step > 0,
         paging = socket.assigns.paging,
         true <- Map.has_key?(paging, id) or map_size(paging) < @max_listings do
      count = min(shown + step, @max_shown)
      {:halt, Phoenix.Component.update(socket, :paging, &Map.put(&1, id, count))}
    else
      _forged -> {:halt, socket}
    end
  end

  defp grow(event, _params, socket) when event in @events, do: {:halt, socket}
  defp grow(_event, _params, socket), do: {:cont, socket}

  @doc "The rows a listing shows at first."
  def page_size, do: @page_size

  @doc "How many rows the listing `id` shows: its first page until it is grown."
  def shown(paging, id, page_size \\ @page_size), do: Map.get(paging || %{}, id, page_size)

  @doc """
  Folds a section shut, or opens it.

  A key the screen never declared opens: it can only have come from a section
  the screen is rendering, and rendering one it cannot toggle would be worse
  than opening it.
  """
  def toggle(socket, key) do
    Phoenix.Component.assign(
      socket,
      :sections,
      Map.update(socket.assigns.sections, key, true, &(!&1))
    )
  end
end
