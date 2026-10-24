defmodule FlezhaConsoleWeb.ObservabilityLiveTest do
  @moduledoc """
  Sources, their meanings and recent activity, sinks, toggles and the tail.

  A disabled subsystem, a refused toggle, a disabled pubsub sink and a
  controller that does not describe its sources are the states this screen
  exists to explain, and none of them can be produced on a working dev
  controller.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Observability

  # Entries as a live controller answers them, trimmed to what the screen reads.
  @file_sink %{
    name: :flezha_file_sink,
    status: :active,
    kinds: [:metric, :event],
    flavour: :declarative,
    cardinality_budget: 1000,
    area: :plugins,
    title: "File sink plugin",
    description: "The plugin that writes a relay's output to a file.",
    signals: [
      %{
        name: :refused,
        kind: :event,
        label: "Record refused",
        outcome: :failure,
        description: "A record was refused because it cannot be written as one line.",
        sentence: "{plugin_id} refused a record for {path}"
      },
      %{
        name: :failed,
        kind: :event,
        label: "Write failed",
        outcome: :failure,
        description: "Writing to the file failed; it will be tried again.",
        sentence: "{plugin_id} could not write to {path}"
      },
      %{
        name: :flushed,
        kind: :metric,
        label: "Saved",
        outcome: :normal,
        description: "Records were written to the file.",
        sentence: "{plugin_id} saved {count:record} to {path}"
      }
    ],
    recent: %{window_ms: 900_000, signals: %{flushed: %{count: 42, last_age_ms: 3_000}}}
  }

  @http_poll %{
    name: :flezha_http_poll,
    status: :active,
    kinds: [:metric, :event],
    flavour: :declarative,
    cardinality_budget: 1000,
    area: :plugins,
    title: "HTTP poll plugin",
    description: "The plugin that reads a URL on a timer and hands what changed to a relay.",
    signals: [
      %{
        name: :failed,
        kind: :event,
        label: "Poll failed",
        outcome: :failure,
        description: "A poll request failed."
      }
    ],
    recent: %{window_ms: 900_000, signals: %{}}
  }

  @authz %{
    name: :platform_authz,
    status: :disabled,
    kinds: [:event, :metric],
    flavour: :declarative,
    cardinality_budget: 256,
    area: :controller,
    title: "Access control",
    description:
      "Calls refused for lack of a role, tokens issued and revoked, and the first administrator's setup.",
    signals: [
      %{
        name: :token_issued,
        kind: :event,
        label: "Token issued",
        outcome: :normal,
        description: "A token was issued."
      }
    ],
    recent: %{window_ms: 900_000, signals: %{}}
  }

  defp sources(node, list) do
    FakeController.set(node, {Observability, :list_sources}, {:ok, list})
  end

  defp source_order(view, group) do
    view
    |> element(~s([data-testid="source-group-#{group}"]))
    |> render()
    |> testids("tr[role=row]")
    |> Enum.map(&String.replace_prefix(&1, "source-", ""))
  end

  defp toggle(view, source),
    do: view |> element(~s([data-testid="toggle-#{source}"])) |> render_click()

  describe "finding a source" do
    test "the filter matches titles, names and descriptions, and the area still counts them all",
         %{conn: conn, node: node} do
      sources(node, [@file_sink, @http_poll, @authz])
      {:ok, view, _html} = live(conn, ~p"/observability")

      filter = fn text ->
        view
        |> element(~s([data-testid="source-filter-form"]))
        |> render_change(%{"q" => text})
      end

      html = filter.("file")
      assert html =~ ~s(data-testid="source-flezha_file_sink")
      refute html =~ ~s(data-testid="source-flezha_http_poll")
      assert html =~ ~s(data-testid="source-group-plugins")

      html = filter.("access control")
      assert html =~ ~s(data-testid="source-platform_authz")
      refute html =~ ~s(data-testid="source-flezha_file_sink")

      html = filter.("authz")
      assert html =~ ~s(data-testid="source-platform_authz")

      html = filter.("reads a url")
      assert html =~ ~s(data-testid="source-flezha_http_poll")
      refute html =~ ~s(data-testid="source-flezha_file_sink")

      assert view |> element(~s([data-testid="source-group-count-plugins"])) |> render() =~
               "2 of 2 on"
    end
  end

  describe "listing" do
    test "each source is grouped by its declared area, headed by its title", %{
      conn: conn,
      node: node
    } do
      sources(node, [@file_sink, @authz])
      {:ok, view, html} = live(conn, ~p"/observability")

      assert html =~ ~s(data-testid="source-group-plugins")
      assert html =~ ~s(data-testid="source-group-controller")
      assert html =~ "Plugins"
      assert html =~ ~r/data-testid="source-enabled-flezha_file_sink"[^>]*data-enabled="true"/
      assert html =~ ~r/data-testid="source-enabled-platform_authz"[^>]*data-enabled="false"/

      row = view |> element(~s([data-testid="source-flezha_file_sink"])) |> render()

      assert row =~
               ~r/class="block fcon-label"[^>]*>\s*File sink plugin\s*</

      assert row =~ ~r/class="block fcon-tech-name">flezha_file_sink</

      assert row =~
               ~r/class="block fcon-hint"[^>]*>\s*The plugin that writes a relay&#39;s output/
    end

    test "a failure in the window is counted with its age, and its source sorts first", %{
      conn: conn,
      node: node
    } do
      failing =
        put_in(@file_sink.recent.signals, %{
          failed: %{count: 3, last_age_ms: 420_000},
          flushed: %{count: 12, last_age_ms: 1_000}
        })

      # Listed second on purpose: the screen puts the failing one on top.
      sources(node, [@http_poll, failing])
      {:ok, view, _html} = live(conn, ~p"/observability")

      badge = view |> element(~s([data-testid="source-failures-flezha_file_sink"])) |> render()
      assert badge =~ "fcon-badge--warning"
      assert badge =~ ~r/⚠ 3 failures in the last 15m, latest 7m ago/

      assert view |> element(~s([data-testid="source-activity-flezha_file_sink"])) |> render() =~
               "12 saved · last 1s ago"

      assert source_order(view, "plugins") == ["flezha_file_sink", "flezha_http_poll"]
    end

    test "a quiet source with failure signals reassures; one without says nothing was emitted",
         %{conn: conn, node: node} do
      quiet = %{@authz | recent: %{window_ms: 900_000, signals: %{}}}
      sources(node, [@http_poll, quiet])
      {:ok, view, _html} = live(conn, ~p"/observability")

      ok = view |> element(~s([data-testid="source-no-failures-flezha_http_poll"])) |> render()
      assert ok =~ "fcon-badge--positive"
      assert ok =~ "✓ No failures in the last 15m"

      line = view |> element(~s([data-testid="source-activity-platform_authz"])) |> render()
      assert line =~ "Nothing in the last 15m"
      refute line =~ "No failures"
    end

    test "normal activity is told by labels, the three most frequent first", %{
      conn: conn,
      node: node
    } do
      signals =
        for {name, label} <- [a: "Read", b: "Sent", c: "HTTP request", d: "Saved"],
            do: %{name: name, kind: :metric, label: label, outcome: :normal, description: "x"}

      recent = %{
        window_ms: 900_000,
        signals:
          Map.new(
            [a: 1, b: 5, c: 3, d: 12_400],
            fn {name, count} -> {name, %{count: count, last_age_ms: 2_000}} end
          )
      }

      sources(node, [%{@file_sink | signals: signals, recent: recent}])
      {:ok, view, _html} = live(conn, ~p"/observability")

      assert view |> element(~s([data-testid="source-activity-flezha_file_sink"])) |> render() =~
               "12.4k saved · 5 sent · 3 HTTP request · 1 more · last 2s ago"
    end

    test "a source that spoke sorts above a quiet one, each band by title", %{
      conn: conn,
      node: node
    } do
      spoke = %{@authz | name: :zz_spoke, area: :plugins, title: "Zebra"}
      spoke = put_in(spoke.recent.signals, %{token_issued: %{count: 1, last_age_ms: 1_000}})
      quiet = %{@authz | name: :aa_quiet, area: :plugins, title: "Aardvark"}
      sources(node, [quiet, spoke])
      {:ok, view, _html} = live(conn, ~p"/observability")

      assert source_order(view, "plugins") == ["zz_spoke", "aa_quiet"]
    end

    test "a controller that does not describe its sources still lists them by name", %{
      conn: conn,
      node: node
    } do
      sources(node, [%{name: :flezha_health, status: :active}])
      {:ok, _view, html} = live(conn, ~p"/observability")

      assert html =~ ~s(data-testid="source-group-other")
      assert html =~ ~s(data-testid="source-flezha_health")
      assert html =~ ~r/data-testid="source-title-flezha_health"[^>]*>\s*flezha_health\s*</
      refute html =~ ~s(data-testid="source-description-flezha_health")
      refute html =~ ~s(data-testid="source-activity-flezha_health")
      assert html =~ ~s(data-testid="tail-flezha_health")
    end

    test "a controller before titles and outcomes is listed by name, with plain activity", %{
      conn: conn,
      node: node
    } do
      old =
        @file_sink
        |> Map.delete(:title)
        |> Map.update!(:signals, fn signals ->
          Enum.map(signals, &Map.drop(&1, [:label, :outcome, :sentence]))
        end)

      sources(node, [put_in(old.recent.signals, %{failed: %{count: 2, last_age_ms: 1_000}})])
      {:ok, view, html} = live(conn, ~p"/observability")

      assert html =~ ~r/data-testid="source-title-flezha_file_sink"[^>]*>\s*flezha_file_sink\s*</
      line = view |> element(~s([data-testid="source-activity-flezha_file_sink"])) |> render()
      assert line =~ "2 failed · last 1s ago"
      refute line =~ "fcon-badge"
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

      assert [["platform_authz", %{source: :ui}]] =
               FakeController.calls(node, {Observability, :enable_source})
    end

    test "disabling an enabled source calls disable_source", %{conn: conn, node: node} do
      sources(node, [%{@authz | status: :active}])

      {:ok, view, _html} = live(conn, ~p"/observability")
      toggle(view, "platform_authz")

      assert [["platform_authz", _ctx]] =
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

      assert [["flezha_file_sink", %{source: :ui, emit: emit}]] =
               FakeController.calls(node, @tail)

      assert is_pid(emit)
    end

    test "nothing yet: the drawer leads with what the source is and lists what it can say", %{
      conn: conn,
      node: node
    } do
      view = start_tail(conn, node)
      panel = view |> element(~s([data-testid="tail-panel"])) |> render()

      assert panel =~ ~r/class="fcon-drawer-title"[^>]*>File sink plugin</
      assert panel =~ ~r/class="fcon-tech-name"[^>]*>\s*flezha_file_sink\s*</
      assert panel =~ ~r/data-testid="tail-lead"[^>]*>\s*The plugin that writes/
      assert panel =~ ~r/data-testid="tail-count"[^>]*>\s*Waiting for the first signal/
      assert panel =~ ~s(class="fcon-empty")
      assert panel =~ "Nothing yet — this source speaks when something happens."

      failures = view |> element(~s([data-testid="tail-meanings-failure"])) |> render()
      assert failures =~ "When something goes wrong"
      assert failures =~ "Record refused"
      assert failures =~ "⚠ Failure"
      assert failures =~ "A record was refused because it cannot be written as one line."
      assert failures =~ ~r/class="block fcon-tech-name">refused</
      assert failures =~ ~r/class="block fcon-tech-name">failed</
      refute failures =~ "Saved"

      normal = view |> element(~s([data-testid="tail-meanings-normal"])) |> render()
      assert normal =~ "Normal activity"
      assert normal =~ "Saved"
      assert normal =~ ~r/class="fcon-badge">Normal</
      assert normal =~ ~r/class="block fcon-tech-name">flushed</
    end

    test "a line is one sentence about its subject, its fields behind Details", %{
      conn: conn,
      node: node
    } do
      view = start_tail(conn, node)

      FakeController.emit(
        node,
        @tail,
        signal(:flushed, controller_now(node), %{
          measurements: %{count: 1},
          metadata: %{plugin_id: "showcase_orders", path: "/data/out.log"}
        })
      )

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tail-record") end)
      line = view |> element(~s([data-testid="tail-record"])) |> render()

      assert line =~
               ~r/data-testid="tail-sentence"[^>]*>\s*showcase_orders saved 1 record to out.log\s*</

      assert line =~ ~r/<details id="tail-line-\d+"[^>]*data-testid="tail-details"/
      assert line =~ "Details"
      assert line =~ "path=/data/out.log plugin_id=showcase_orders"
      assert line =~ "count 1"
      assert line =~ ~r/\d\d:\d\d:\d\d\.\d\d\d/
      refute line =~ "tail-failure-mark"

      assert view |> element(~s([data-testid="tail-count"])) |> render() =~
               ~r/Live · 1 signal · newest first/

      html = render(view)
      refute html =~ ~s(data-testid="tail-waiting")
      assert html =~ ~s(data-testid="tail-meanings-fold")

      refute render(view) =~ ~s(data-testid="tail-history-divider")
    end

    test "a count reads with its noun and a large one compactly", %{conn: conn, node: node} do
      view = start_tail(conn, node)

      FakeController.emit(
        node,
        @tail,
        signal(:flushed, controller_now(node), %{
          measurements: %{count: 12_400},
          metadata: %{plugin_id: "orders", path: "/var/out/day.log"}
        })
      )

      assert PeerNode.eventually(fn ->
               render(view) =~ "orders saved 12.4k records to day.log"
             end)
    end

    test "a failure carries a warning mark in the warning tone", %{conn: conn, node: node} do
      view = start_tail(conn, node)

      FakeController.emit(
        node,
        @tail,
        signal(:failed, controller_now(node), %{
          kind: :event,
          metadata: %{plugin_id: "orders", path: "/data/out.log", reason: :enospc}
        })
      )

      assert PeerNode.eventually(fn -> render(view) =~ "tail-failure-mark" end)
      line = view |> element(~s([data-testid="tail-record"])) |> render()

      assert line =~ ~s(data-outcome="failure")
      assert line =~ ~r/class="min-w-0 fcon-tone-warning"/
      assert line =~ "⚠"
      assert line =~ "orders could not write to out.log"
    end

    test "a template naming a value the signal lacks reads its subject and label", %{
      conn: conn,
      node: node
    } do
      view = start_tail(conn, node)

      FakeController.emit(
        node,
        @tail,
        signal(:flushed, controller_now(node), %{metadata: %{plugin_id: "orders"}})
      )

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tail-record") end)
      sentence = view |> element(~s([data-testid="tail-sentence"])) |> render()

      assert sentence =~ ~r/>\s*orders: Saved\s*</
      refute sentence =~ "{"
    end

    test "a signal the source does not declare reads by its name", %{conn: conn, node: node} do
      view = start_tail(conn, node)
      FakeController.emit(node, @tail, signal(:rotated, controller_now(node)))

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tail-record") end)

      assert view |> element(~s([data-testid="tail-sentence"])) |> render() =~
               ~r/>\s*rotated\s*</
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
      assert html =~ ~r/class="fcon-eyebrow pt-3 pb-1"\s+data-testid="tail-history-divider"/
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
