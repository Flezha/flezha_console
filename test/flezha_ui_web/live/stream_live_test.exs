defmodule FlezhaUiWeb.StreamLiveTest do
  @moduledoc """
  The stream screen for a running operative.

  The browser suite drives the controls against a live stream. What it cannot
  produce is the listener being refused, or a message arriving while the feed
  is paused — both of which arrive here as messages the screen already handles.
  """

  use FlezhaUiWeb.LiveCase

  @url "/namespaces/default/operatives/op_a/stream"

  defp message(text, ts \\ nil) do
    %{
      message: text,
      timestamp: ts || System.system_time(:millisecond),
      metadata: %{}
    }
  end

  describe "connecting" do
    test "starts on the output stream and reports it is connecting", %{conn: conn} do
      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="stream-connecting")
      assert html =~ "output"
      assert html =~ "op_a"
    end

    test "renders the feed once the bridge reports it connected", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)

      send(view.pid, {:stream_status, :connected})
      html = render(view)

      assert html =~ ~s(data-testid="stream-empty")
      refute html =~ ~s(data-testid="stream-connecting")
    end

    test "explains a listener the controller refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)

      send(view.pid, {:stream_status, {:error, :refused}})
      html = render(view)

      # The state the browser suite cannot reach: the dev stack always accepts.
      assert html =~ ~s(data-testid="stream-error")
      assert html =~ "Failed to connect"
    end
  end

  describe "messages" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)
      send(view.pid, {:stream_status, :connected})
      %{view: view}
    end

    test "renders an arriving message and counts it", %{view: view} do
      send(view.pid, {:stream_message, message("hello from the operative")})
      html = render(view)

      assert html =~ ~s(data-testid="stream-message")
      assert html =~ "hello from the operative"
      assert html =~ "1 messages received"
    end

    test "a paused feed still counts but does not render", %{view: view} do
      render_click(view, "toggle_pause", %{})

      send(view.pid, {:stream_message, message("arrived while paused")})
      html = render(view)

      assert html =~ "(paused)"
      refute html =~ "arrived while paused"
    end

    test "clearing drops the messages and the count", %{view: view} do
      send(view.pid, {:stream_message, message("first")})
      assert render(view) =~ "first"

      html = render_click(view, "clear", %{})

      refute html =~ "first"
      assert html =~ "0 messages received"
    end

    test "the filter narrows what is rendered without dropping the count", %{view: view} do
      send(view.pid, {:stream_message, message("keep me")})
      send(view.pid, {:stream_message, message("drop me")})

      html = render_change(view, "set_filter", %{"filter" => "keep"})

      assert html =~ "keep me"
      refute html =~ "drop me"
      # Filtering is a view concern; the messages are still there.
      assert html =~ "2 messages received"
    end

    test "an invalid filter regex does not crash the feed", %{view: view} do
      send(view.pid, {:stream_message, message("still here")})

      html = render_change(view, "set_filter", %{"filter" => "["})

      assert html =~ ~s(data-testid="stream-feed")
    end
  end

  describe "switching streams" do
    test "resets the feed and reconnects", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)
      send(view.pid, {:stream_status, :connected})
      send(view.pid, {:stream_message, message("an output message")})
      assert render(view) =~ "an output message"

      html = render_click(view, "switch_io", %{"type" => "input"})

      # A stale message from the other stream would misattribute it.
      refute html =~ "an output message"
      assert html =~ ~s(data-testid="stream-connecting")
      assert html =~ "input"
    end
  end
end
