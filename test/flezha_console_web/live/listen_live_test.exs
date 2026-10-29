defmodule FlezhaConsoleWeb.ListenLiveTest do
  @moduledoc """
  The listen screen for a running relay, driven through a real `EventFeed`
  over `Relay.listen/5` against the controller stand-in.

  The browser suite drives the controls against a live relay. What it cannot
  produce is the listen being refused, or the relay ending under it.
  """

  use FlezhaConsoleWeb.LiveCase

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

  defp filter(view, value) do
    view |> form(~s(form[phx-change="set_filter"]), %{"filter" => value}) |> render_change()
  end

  defp listening(conn) do
    {:ok, view, _html} = live(conn, @url)
    eventually_renders(view, ~s(data-testid="listen-empty"))
    view
  end

  describe "partitions" do
    test "a partition member's menu opens another partition on Listen", %{conn: conn, node: node} do
      partition_group(node, "orders", 2)

      {:ok, view, html} = live(conn, "/namespaces/default/relays/orders%23p1/listen")

      assert text_of(html, ~s([data-testid="partition-menu"])) == "Partition p1 of 2"

      assert {:error, {:live_redirect, %{to: "/namespaces/default/relays/orders%23p0/listen"}}} =
               view |> element(~s([data-testid="partition-menu-orders#p0"])) |> render_click()
    end
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

    test "listens to a relay hosted on another controller as to one on this", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows([FakeController.relay_row("relay_a", %{node: :"flezha@node-b"})])
      )

      FakeController.set(
        node,
        {Flezha.Service.Fleet, :runners_for_factory},
        FakeController.rows(["runner-b"])
      )

      html = render(listening(conn))

      assert html =~ ~s(data-testid="listen-send")
      refute html =~ ~s(data-testid="listen-unservable")

      # The relay is named, never its controller: the controller routes the listen.
      assert [["default", "relay_a", :output, [], %{source: :ui}]] =
               FakeController.calls(node, @listen)
    end

    test "offers a send but no call to a relay no runner can run", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows([FakeController.relay_row("relay_a")])
      )

      FakeController.set(
        node,
        {Flezha.Service.Fleet, :runners_for_factory},
        FakeController.rows([])
      )

      view = listening(conn)
      html = render(view)

      assert text_of(html, ~s([data-testid="listen-send"])) ==
               "Send to relay_a to see something arrive."

      note = text_of(html, ~s([data-testid="listen-unservable"]))
      assert note =~ "the controller keeps the message only if this relay journals its input"

      assert note =~
               "Call is off. Nobody can answer a call until a runner serves factory store_input"
    end

    test "reads the relay's own suspended flag, which the registry can lag", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows([FakeController.relay_row("relay_a")])
      )

      FakeController.set(node, {Relay, :overwatch_state}, {:ok, %{phase: :suspended}})

      FakeController.set(
        node,
        {Flezha.Service.Fleet, :runners_for_factory},
        FakeController.rows([])
      )

      note = text_of(render(listening(conn)), ~s([data-testid="listen-unservable"]))
      assert note =~ "No runner serves store_input yet; the message is kept until one connects."
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

    test "a refusal is one error statement, outside the feed, with its next step and reference",
         %{conn: conn, node: node} do
      FakeController.set(
        node,
        @listen,
        {:error,
         Flezha.Error.new(
           "relay.not_running",
           "relay 'orders' is not running",
           "flz relay list --namespace default"
         )}
      )

      {:ok, view, _html} = live(conn, @url)
      html = eventually_renders(view, ~s(data-testid="listen-error"))

      statement = ~s([data-testid="listen-error"] [data-testid="runtime-error"])
      assert html |> LazyHTML.from_document() |> LazyHTML.query(statement) |> Enum.count() == 1
      assert text_of(html, statement) =~ "relay orders is not running"

      assert text_of(html, ~s(#{statement} [data-testid="runtime-error-hint"])) ==
               "flz relay list --namespace default"

      assert text_of(html, ~s(#{statement} [data-testid="runtime-error-code"])) ==
               "relay.not_running"

      assert html =~ ~r{href="[^"]*/errors\.html#relay"}
      refute html =~ ~s(data-testid="listen-feed")
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

      assert html =~ received(1)
    end

    test "a burst of records renders once, keeping the newest", %{view: view} do
      lv = view.pid
      test_pid = self()
      handler = "listen-burst-#{inspect(test_pid)}"

      :telemetry.attach(
        handler,
        [:phoenix, :live_view, :render, :stop],
        fn _event, _measurements, _meta, _config ->
          if self() == lv, do: send(test_pid, :rendered)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # Held while the burst queues, as a busy relay outpaces the screen.
      :sys.suspend(lv)
      for i <- 1..500, do: send(lv, {:feed_event, :listen, {:output, "burst #{i}", %{}}})
      :sys.resume(lv)

      html = eventually_renders(view, received(500))
      assert html =~ ~r/burst 500\b/
      assert html =~ ~r/burst 301\b/
      refute html =~ ~r/burst 300\b/

      renders = Stream.repeatedly(fn -> receive do: (:rendered -> 1), after: (0 -> nil) end)
      assert renders |> Enum.take_while(& &1) |> length() <= 2
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
      view |> element(~s([data-testid="listen-pause"])) |> render_click()

      FakeController.emit(node, @listen, {:output, "arrived while paused", %{}})
      html = eventually_renders(view, received(1))

      assert html =~ "(paused)"
      refute html =~ "arrived while paused"
    end

    test "clearing drops the messages and the count", %{view: view, node: node} do
      FakeController.emit(node, @listen, {:output, "first", %{}})
      eventually_renders(view, "first")

      html = view |> element(~s([data-testid="listen-clear"])) |> render_click()

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

      html = filter(view, "keep")

      assert html =~ "keep me"
      refute html =~ "drop me"
      # Filtering is a view concern; the messages are still there.
      assert html =~ received(2)
    end

    test "an invalid filter regex is reported and shows everything", %{view: view, node: node} do
      FakeController.emit(node, @listen, {:output, "still here", %{}})
      eventually_renders(view, "still here")

      html = filter(view, "[")

      assert html =~ "Not a regular expression"
      assert html =~ "still here"

      refute filter(view, "still") =~ "listen-filter-error"
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
