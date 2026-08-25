defmodule FlezhaUiWeb.Live.Sections do
  @moduledoc """
  Which of a long screen's panels are open.

  A screen carrying more than four panels opens on what the operator came for
  and folds the rest away. Which ones start open is the screen's own decision,
  declared once where the screen is defined:

      use FlezhaUiWeb.Live.Sections,
        open: %{"journal" => false, "inbox" => false}

      def mount(_params, _session, socket) do
        {:ok, socket |> sections_init() |> load()}
      end

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
        {:noreply, FlezhaUiWeb.Live.Sections.toggle(socket, key)}
      end
    end
  end

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
