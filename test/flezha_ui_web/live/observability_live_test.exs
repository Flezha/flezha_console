defmodule FlezhaUiWeb.ObservabilityLiveTest do
  @moduledoc """
  Sources, their meanings and recent activity, sinks, toggles and the tail.

  A disabled subsystem, a refused toggle, a disabled pubsub sink and a
  controller that does not describe its sources are the states this screen
  exists to explain, and none of them can be produced on a working dev
  controller.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Observability

  # Entries as a live controller answers them, trimmed to what the screen reads.
  @file_sink %{
    name: :flezha_file_sink,
    status: :active,
    kinds: [:event, :metric],
    flavour: :declarative,
    cardinality_budget: 1000,
    area: :plugins,
    description: "The file sink plugin, which writes relay output to a file.",
    signals: [
      %{
        name: :refused,
        kind: :event,
        description: "A record was refused because it cannot be written as one line."
      },
      %{name: :failed, kind: :event, description: "Writing to the file failed."},
      %{
        name: :flushed,
        kind: :metric,
        description: "Lines were written to the file; count is how many."
      }
    ],
    recent: %{window_ms: 900_000, signals: %{flushed: %{count: 42, last_age_ms: 3_000}}}
  }

  @http_poll %{
    name: :flezha_http_poll,
    status: :active,
    kinds: [:event, :metric],
    flavour: :declarative,
    cardinality_budget: 1000,
    area: :plugins,
    description: "The HTTP poll plugin, which reads a URL on a timer.",
    signals: [%{name: :failed, kind: :event, description: "A poll request failed."}],
    recent: %{window_ms: 900_000, signals: %{}}
  }

  @authz %{
    name: :platform_authz,
    status: :disabled,
    kinds: [:event, :metric],
    flavour: :declarative,
    cardinality_budget: 256,
    area: :controller,
    description: "Authorization: refused calls, tokens and the first-time bootstrap.",
    signals: [%{name: :token_issued, kind: :event, description: "A token was issued."}],
    recent: %{window_ms: 900_000, signals: %{}}
  }

  defp sources(node, list) do
    FakeController.set(node, {Observability, :list_sources}, {:ok, list})
  end

  defp toggle(view, source),
    do: view |> element(~s([data-testid="toggle-#{source}"])) |> render_click()

  describe "finding a source" do
    test "the filter matches names and descriptions, and the area still counts them all", %{
      conn: conn,
      node: node
    } do
      sources(node, [@file_sink, @http_poll, @authz])
      {:ok, view, _html} = live(conn, ~p"/observability")

      filter = fn text ->
        view
        |> element(~s([data-testid="source-filter-form"]))
        |> render_change(%{"q" => text})
      end

      html = filter.("writes relay output")
      assert html =~ ~s(data-testid="source-flezha_file_sink")
      refute html =~ ~s(data-testid="source-flezha_http_poll")

      html = filter.("authz")
      assert html =~ ~s(data-testid="source-platform_authz")
      refute html =~ ~s(data-testid="source-flezha_file_sink")

      assert view |> element(~s([data-testid="source-group-count-plugins"])) |> render() =~
               "2 of 2 on"
    end
  end

  describe "listing" do
    test "each source is grouped by its declared area and says what it is", %{
      conn: conn,
      node: node
    } do
      sources(node, [@file_sink, @authz])
      {:ok, _view, html} = live(conn, ~p"/observability")

      assert html =~ ~s(data-testid="source-group-plugins")
      assert html =~ ~s(data-testid="source-group-controller")
      assert html =~ "Plugins"
      assert html =~ "The file sink plugin, which writes relay output to a file."
      assert html =~ ~r/data-testid="source-enabled-flezha_file_sink"[^>]*data-enabled="true"/
      assert html =~ ~r/data-testid="source-enabled-platform_authz"[^>]*data-enabled="false"/
    end

    test "a source that spoke says what and when; a quiet one names the window, and speaks last",
         %{conn: conn, node: node} do
      busy =
        put_in(@file_sink.recent.signals, %{
          flushed: %{count: 12_400, last_age_ms: 3_000},
          failed: %{count: 1, last_age_ms: 120_000}
        })

      # Listed quiet-first on purpose: the screen puts the one that spoke on top.
      sources(node, [@http_poll, busy])
      {:ok, view, _html} = live(conn, ~p"/observability")

      active = view |> element(~s([data-testid="source-activity-flezha_file_sink"])) |> render()
      assert active =~ "flushed ×12.4k · failed ×1 · last 3s ago"

      quiet = view |> element(~s([data-testid="source-activity-flezha_http_poll"])) |> render()
      assert quiet =~ "Nothing in the last 15m"

      group = view |> element(~s([data-testid="source-group-plugins"])) |> render()

      [first, second] =
        Regex.scan(~r/data-testid="source-(flezha_[a-z_]+)"/, group, capture: :all_but_first)

      assert {first, second} == {["flezha_file_sink"], ["flezha_http_poll"]}
    end

    test "a source with more than three signals names the three most frequent", %{
      conn: conn,
      node: node
    } do
      recent = %{
        window_ms: 900_000,
        signals:
          Map.new(
            [a: 1, b: 5, c: 3, d: 9],
            fn {name, count} -> {name, %{count: count, last_age_ms: 1_000}} end
          )
      }

      sources(node, [%{@file_sink | recent: recent}])
      {:ok, view, _html} = live(conn, ~p"/observability")

      assert view |> element(~s([data-testid="source-activity-flezha_file_sink"])) |> render() =~
               "d ×9 · b ×5 · c ×3 · 1 more · last 1s ago"
    end

    test "a controller that does not describe its sources still lists them by name", %{
      conn: conn,
      node: node
    } do
      sources(node, [%{name: :flezha_health, status: :active}])
      {:ok, view, html} = live(conn, ~p"/observability")

      assert html =~ ~s(data-testid="source-group-other")
      assert html =~ ~s(data-testid="source-flezha_health")
      refute html =~ ~s(data-testid="source-description-flezha_health")

      assert view |> element(~s([data-testid="source-activity-flezha_health"])) |> render() =~
               ~r/>\s*<\/span>/

      assert html =~ ~s(data-testid="tail-flezha_health")
    end

    test "one line names each sink and what it is for, and marks one that is not running", %{
      conn: conn,
      node: node
    } do
      sources(node, [@file_sink])

      FakeController.set(
        node,
        {Observability, :list_sinks},
        {:ok,
         [
           %{name: :pubsub, module: Flezha.Observability.PubSubSink, pid: self()},
           %{name: :ring_buffer, module: Flezha.Observability.RingBufferSink, pid: nil},
           %{name: :custom, module: Some.Sink, pid: self()}
         ]}
      )

      {:ok, view, _html} = live(conn, ~p"/observability")
      line = view |> element(~s([data-testid="sinks-line"])) |> render()

      assert line =~ "live tails"
      assert line =~ "recent history"
      assert line =~ "custom"
      assert line =~ ~s(data-testid="sink-stopped-ring_buffer")
      refute line =~ ~s(data-testid="sink-stopped-pubsub")
    end

    test "a switched-off subsystem is stated as switched off", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Observability, :list_sources},
        FakeController.error("observability.disabled")
      )

      {:ok, _view, html} = live(conn, ~p"/observability")

      assert html =~ ~s(data-testid="observability-disabled")
      assert html =~ "switched off"
      refute html =~ ~s(data-testid="sources-panel")
    end
  end

  describe "toggling" do
    test "enabling a disabled source calls enable_source with the UI's context", %{
      conn: conn,
      node: node
    } do
      sources(node, [@authz])

      {:ok, view, _html} = live(conn, ~p"/observability")
      toggle(view, "platform_authz")

      assert [[:platform_authz, %{source: :ui}]] =
               FakeController.calls(node, {Observability, :enable_source})
    end

    test "disabling an enabled source calls disable_source", %{conn: conn, node: node} do
      sources(node, [%{@authz | status: :active}])

      {:ok, view, _html} = live(conn, ~p"/observability")
      toggle(view, "platform_authz")

      assert [[:platform_authz, _ctx]] =
               FakeController.calls(node, {Observability, :disable_source})
    end

    test "a refused toggle is shown and the source is unchanged", %{conn: conn, node: node} do
      sources(node, [@authz])

      FakeController.set(
        node,
        {Observability, :enable_source},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/observability")
      html = toggle(view, "platform_authz")

      assert html =~ "refused"
      assert html =~ "authz.role_insufficient"
      assert html =~ ~r/data-testid="source-enabled-platform_authz"[^>]*data-enabled="false"/
    end

    test "a forged toggle of a source the listing does not name calls nothing", %{
      conn: conn,
      node: node
    } do
      sources(node, [@authz])

      {:ok, view, _html} = live(conn, ~p"/observability")
      render_click(view, "toggle_source", %{"source" => "not_a_source"})

      assert FakeController.calls(node, {Observability, :enable_source}) == []
    end
  end

  describe "the tail" do
    @tail {Observability, :tail}
    @query {Observability, :query}

    setup %{node: node} do
      sources(node, [@file_sink])
      :ok
    end

    defp signal(name, ts, fields \\ %{}) do
      Map.merge(
        %{
          __struct__: Flezha.Observability.Signal,
          kind: :metric,
          ts: ts,
          source: :flezha_file_sink,
          name: name,
          measurements: %{count: 1},
          metadata: %{}
        },
        fields
      )
    end

    defp controller_now(node) do
      {:ok, %{monotonic_us: now}} =
        :erpc.call(node, Flezha.Service.Controller, :status, [%{source: :ui}])

      now
    end

    defp open(conn) do
      {:ok, view, _html} = live(conn, ~p"/observability")
      view |> element(~s([data-testid="tail-flezha_file_sink"])) |> render_click()
      view
    end

    defp start_tail(conn, node) do
      view = open(conn)
      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) != [] end)
      view
    end

    test "tailing reads the history and takes the published tail with the UI's context", %{
      conn: conn,
      node: node
    } do
      start_tail(conn, node)

      # The shell reads other sources' history too; this is the tail's own read.
      assert [[%{source: :flezha_file_sink, limit: 50}, %{source: :ui}]] =
               Enum.filter(FakeController.calls(node, @query), fn [params, _ctx] ->
                 params.source == :flezha_file_sink
               end)

      assert [[:flezha_file_sink, %{source: :ui, emit: emit}]] = FakeController.calls(node, @tail)
      assert is_pid(emit)
    end

    test "nothing yet: the drawer says what the source can say", %{conn: conn, node: node} do
      view = start_tail(conn, node)
      html = view |> element(~s([data-testid="tail-waiting"])) |> render()

      assert html =~ "Nothing yet"
      assert html =~ "flushed"
      assert html =~ "Lines were written to the file; count is how many."
      assert html =~ "refused"
      assert html =~ "failed"
    end

    test "a line says when, what, about whom and how much", %{conn: conn, node: node} do
      view = start_tail(conn, node)

      FakeController.emit(
        node,
        @tail,
        signal(:flushed, controller_now(node), %{
          measurements: %{count: 1},
          metadata: %{plugin_id: "file_sink#3", path: "/data/out.log"}
        })
      )

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tail-record") end)
      line = view |> element(~s([data-testid="tail-record"])) |> render()

      assert line =~ "flushed"
      assert line =~ "Lines were written to the file; count is how many."
      assert line =~ "path=/data/out.log plugin_id=file_sink#3"
      assert line =~ "count 1"
      assert line =~ ~r/\d\d:\d\d:\d\d\.\d\d\d/
      refute render(view) =~ ~s(data-testid="tail-history-divider")
    end

    test "an atom label reads as a word, and a long one is cut", %{conn: conn, node: node} do
      view = start_tail(conn, node)
      long = String.duplicate("x", 500)

      FakeController.emit(
        node,
        @tail,
        signal(:failed, controller_now(node), %{metadata: %{transport: :uds, error: long}})
      )

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tail-record") end)
      line = view |> element(~s([data-testid="tail-record"])) |> render()

      assert line =~ "transport=uds"
      assert line =~ "error=" <> String.duplicate("x", 120)
      refute line =~ String.duplicate("x", 121)
    end

    test "history opens the tail under a divider, and live signals arrive above it", %{
      conn: conn,
      node: node
    } do
      now = controller_now(node)

      FakeController.set(
        node,
        @query,
        {:ok, [signal(:failed, now - 120_000_000), signal(:flushed, now - 60_000_000)]}
      )

      view = start_tail(conn, node)

      html = view |> element(~s([data-testid="tail-panel"])) |> render()
      assert html =~ ~s(data-testid="tail-history-divider")
      assert html =~ "Before you opened the tail"
      assert [[_, a], [_, b]] = Regex.scan(~r/(\d\d:\d\d:\d\d)\.\d\d\d/, html)
      # Newest first, and a minute of controller time apart.
      assert (seconds(a) - seconds(b)) in [60, 60 - 86_400]

      FakeController.emit(node, @tail, signal(:flushed, now))
      assert PeerNode.eventually(fn -> render(view) =~ "3 signals" end)

      html = render(view)
      {live_at, _} = :binary.match(html, ~s(data-testid="tail-record"))
      {divider_at, _} = :binary.match(html, ~s(data-testid="tail-history-divider"))
      assert live_at < divider_at
    end

    test "history and live signals together keep at most 200", %{conn: conn, node: node} do
      now = controller_now(node)
      history = for i <- 1..50, do: signal(:flushed, now - i * 1_000_000)
      FakeController.set(node, @query, {:ok, Enum.reverse(history)})

      view = start_tail(conn, node)
      for _ <- 1..160, do: FakeController.emit(node, @tail, signal(:flushed, now))

      assert PeerNode.eventually(fn -> render(view) =~ "200 signals" end)
      assert length(Regex.scan(~r/data-testid="tail-record"/, render(view))) == 200
    end

    test "a refused history read is stated and the live tail still runs", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, @query, FakeController.error("authz.role_insufficient"))

      view = start_tail(conn, node)

      assert render(view) =~ "the source&#39;s recent history"
      FakeController.emit(node, @tail, signal(:flushed, controller_now(node)))
      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tail-record") end)
    end

    test "a disabled pubsub sink says so and still shows the history", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, @query, {:ok, [signal(:flushed, controller_now(node))]})
      FakeController.set(node, @tail, FakeController.error("observability.pubsub_disabled"))

      view = open(conn)

      assert PeerNode.eventually(fn ->
               render(view) =~ ~s(data-testid="pubsub-sink-disabled")
             end)

      html = render(view)
      assert html =~ "pubsub sink is disabled"
      assert html =~ ~s(data-testid="tail-record")
    end

    test "another refusal states its code", %{conn: conn, node: node} do
      FakeController.set(node, @tail, FakeController.error("authz.role_insufficient"))

      view = open(conn)

      assert PeerNode.eventually(fn -> render(view) =~ "authz.role_insufficient" end)
      refute render(view) =~ ~s(data-testid="pubsub-sink-disabled")
    end

    test "a stream that ended and was re-opened is announced", %{conn: conn, node: node} do
      view = start_tail(conn, node)

      FakeController.end_stream(node, @tail, {:ok, :window_closed})

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tail-reconnected") end)
      assert length(FakeController.calls(node, @tail)) == 2
    end
  end

  defp seconds(hms) do
    [h, m, s] = hms |> String.split(":") |> Enum.map(&String.to_integer/1)
    h * 3600 + m * 60 + s
  end
end
