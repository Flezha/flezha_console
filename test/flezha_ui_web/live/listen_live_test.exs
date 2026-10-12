defmodule FlezhaUiWeb.ListenLiveTest do
  @moduledoc """
  The listen screen for a running relay, driven through a real `EventFeed`
  over `Relay.listen/5` against the controller stand-in.

  The browser suite drives the controls against a live relay. What it cannot
  produce is the listen being refused, or the relay ending under it.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Relay

  @url "/namespaces/default/relays/relay_a/listen"
  @listen {Relay, :listen}

  defp eventually_renders(view, pattern) do
    assert PeerNode.eventually(fn -> render(view) =~ pattern end),
           "the screen never rendered #{inspect(pattern)}"

    render(view)
  end

  # The count is a live value, so its figure sits in its own element.
  defp received(count), do: ~r/id="listen-count-value"[^>]*data-value="#{count}"/

  defp listening(conn) do
    {:ok, view, _html} = live(conn, @url)
    eventually_renders(view, ~s(data-testid="listen-empty"))
    view
  end

  describe "connecting" do
    test "listens to the relay's outputs and reports when it is attached", %{
      conn: conn,
      node: node
    } do
      {:ok, view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="listen-connecting")
      assert html =~ "relay_a"

      eventually_renders(view, ~s(data-testid="listen-empty"))

      # Nothing has arrived yet, so it offers to send something that would.
      assert has_element?(
               view,
               ~s(a[data-testid="listen-send"][href="/namespaces/default/relays/relay_a?do=talk"])
             )

      assert [["default", "relay_a", :output, [], %{source: :ui}]] =
               FakeController.calls(node, @listen)
    end

    test "states a listen the controller refused, with its code", %{conn: conn, node: node} do
      FakeController.set(
        node,
        @listen,
        FakeController.error("authz.role_insufficient", "viewers may not listen")
      )

      {:ok, view, _html} = live(conn, @url)
      html = eventually_renders(view, ~s(data-testid="listen-error"))

      assert html =~ "authz.role_insufficient"
      assert html =~ "viewers may not listen"
    end

    test "states that the listen is over when the relay ends", %{conn: conn, node: node} do
      view = listening(conn)

      FakeController.end_stream(node, @listen, {:ok, :done})

      assert eventually_renders(view, ~s(data-testid="listen-ended")) =~ "The relay ended"
    end

    test "closing the screen ends the listen on the controller", %{conn: conn, node: node} do
      view = listening(conn)
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)

      GenServer.stop(view.pid)

      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) == [] end)
    end
  end

  describe "frames" do
    setup %{conn: conn} do
      %{view: listening(conn)}
    end

    test "renders an arriving output and counts it", %{view: view, node: node} do
      FakeController.emit(node, @listen, {:output, "hello from the relay", %{}})
      html = eventually_renders(view, "hello from the relay")

      assert html =~ ~s(data-testid="listen-message")
      assert html =~ received(1)
    end

    test "a dead-letter notice is shown with the error's message", %{view: view, node: node} do
      FakeController.emit(
        node,
        @listen,
        {:dead_lettered, Flezha.Error.new("relay.not_running", "the tasklet failed"), %{}}
      )

      html = eventually_renders(view, "the tasklet failed")
      assert html =~ ~s(data-kind="dead_lettered")
    end

    test "a paused feed still counts but does not render", %{view: view, node: node} do
      render_click(view, "toggle_pause", %{})

      FakeController.emit(node, @listen, {:output, "arrived while paused", %{}})
      html = eventually_renders(view, received(1))

      assert html =~ "(paused)"
      refute html =~ "arrived while paused"
    end

    test "clearing drops the messages and the count", %{view: view, node: node} do
      FakeController.emit(node, @listen, {:output, "first", %{}})
      eventually_renders(view, "first")

      html = render_click(view, "clear", %{})

      refute html =~ "first"
      assert html =~ received(0)
    end

    test "the filter narrows what is rendered without dropping the count", %{
      view: view,
      node: node
    } do
      FakeController.emit(node, @listen, {:output, "keep me", %{}})
      FakeController.emit(node, @listen, {:output, "drop me", %{}})
      eventually_renders(view, received(2))

      html = render_change(view, "set_filter", %{"filter" => "keep"})

      assert html =~ "keep me"
      refute html =~ "drop me"
      # Filtering is a view concern; the messages are still there.
      assert html =~ received(2)
    end

    test "an invalid filter regex is reported and shows everything", %{view: view, node: node} do
      FakeController.emit(node, @listen, {:output, "still here", %{}})
      eventually_renders(view, "still here")

      html = render_change(view, "set_filter", %{"filter" => "["})

      assert html =~ ~s(data-testid="listen-filter-error")
      assert html =~ "Not a regular expression"
      assert html =~ "still here"

      refute render_change(view, "set_filter", %{"filter" => "still"}) =~ "listen-filter-error"
    end
  end

  describe "switching direction" do
    test "ends one listen, starts the other and resets the feed", %{conn: conn, node: node} do
      view = listening(conn)
      FakeController.emit(node, @listen, {:output, "an output", %{}})
      eventually_renders(view, "an output")

      html = view |> element(~s([data-testid="listen-direction-input"])) |> render_click()

      # A stale frame from the other direction would misattribute it.
      refute html =~ "an output"

      eventually_renders(view, ~s(data-testid="listen-empty"))
      assert PeerNode.eventually(fn -> length(FakeController.streams(node, @listen)) == 1 end)

      assert [[_, _, :output, _, _], [_, _, :input, _, _]] = FakeController.calls(node, @listen)
    end
  end
end
