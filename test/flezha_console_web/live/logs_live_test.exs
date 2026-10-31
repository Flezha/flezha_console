defmodule FlezhaConsoleWeb.LogsLiveTest do
  @moduledoc """
  The Logs screen, against a controller whose kinds, files and answers a test
  decides.

  The browser suite reads the live controller's audit log and relay history;
  the states covered here — a kind switched off, a refused read, a third kind,
  a controller that did not answer, the Read more cap — are the ones a live
  controller will not produce on request.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Logs

  @tail {Logs, :tail}

  defp stats(rows), do: {:ok, %{controllers: rows, unreachable: []}}
  defp files(rows), do: {:ok, %{files: rows, unreachable: []}}

  defp audited(n, overrides \\ %{}) do
    Map.merge(
      %{
        "ts_us" => 1_793_270_000_000_000 + n,
        "ts_iso" => "2026-10-29T10:00:00.000Z",
        "source" => "relay_service",
        "name" => "start_#{n}",
        "metadata" => %{"outcome" => "ok", "seq" => n},
        "caller" => %{"principal" => "alice@default"},
        "node" => "flezha@c1"
      },
      overrides
    )
  end

  # The params of every logs read, in order.
  defp reads(node), do: node |> FakeController.calls({Logs, :read}) |> Enum.map(&hd/1)

  defp last_read(node) do
    assert [params, %{source: :ui}] = node |> FakeController.calls({Logs, :read}) |> List.last()
    params
  end

  defp click(view, selector), do: view |> element(selector) |> render_click()
  defp testid(id), do: ~s([data-testid="#{id}"])

  defp type_filters(view, fields),
    do: view |> form(testid("logs-filters"), %{"filter" => fields}) |> render_change()

  defp submit_filters(view, fields),
    do: view |> form(testid("logs-filters"), %{"filter" => fields}) |> render_submit()

  defp query_of(path), do: path |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  defp start_tail(view), do: click(view, testid("logs-tail-toggle"))

  describe "the kinds" do
    test "each declared kind is a tab, the one shown marked current", %{conn: conn} do
      {view, html} = live_loaded(conn, ~p"/logs/audit")

      assert text_of(html, testid("logs-tab-audit")) == "Audit log"
      assert text_of(html, testid("logs-tab-relay_history")) == "Relay history"
      assert has_element?(view, ~s([data-testid="logs-tab-audit"][aria-current="page"]))
      refute has_element?(view, ~s([data-testid="logs-tab-relay_history"][aria-current]))
    end

    test "/logs opens the first kind the controller declares", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/logs")
      render_async(view)

      assert_patch(view, ~p"/logs/audit")
    end

    test "a kind added later is listed by the columns it declares", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Logs, :kinds},
        {:ok, Enum.map(~w(audit relay_history deploys), &FakeController.log_kind/1)}
      )

      deploy = %{
        "ts_us" => 1_793_270_000_000_000,
        "name" => "v1.2 to prod",
        "node" => "flezha@c1"
      }

      FakeController.set(node, {Logs, :read}, FakeController.log_page([deploy]))

      {_view, html} = live_loaded(conn, ~p"/logs/deploys")

      assert text_of(html, testid("logs-tab-deploys")) == "Deploys"
      assert html =~ ~s(name="filter[name]")
      assert text_of(html, ".fcon-record-cols") =~ ~r/Time\s*Name\s*Controller/
      assert text_of(html, testid("log-record-head")) =~ ~r/v1\.2 to prod\s*flezha@c1/
      assert last_read(node)[:kind] == "deploys"
    end

    test "an undeclared kind keeps the tabs and says no such log is kept", %{
      conn: conn,
      node: node
    } do
      {_view, html} = live_loaded(conn, ~p"/logs/nope")

      assert text_of(html, testid("logs-unknown-kind")) =~ "keeps no log named nope"
      assert html =~ ~s(data-testid="logs-tab-audit")
      assert FakeController.calls(node, {Logs, :read}) == []
    end

    test "a refused kinds read is stated with the way to bind a token", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Logs, :kinds}, FakeController.error("authz.principal_not_bound"))

      {_view, html} = live_loaded(conn, ~p"/logs/audit")

      assert html =~ ~s(<code data-testid="runtime-error-code">authz.principal_not_bound</code>)
      assert html =~ ~s(href="/users/settings")
      refute html =~ ~s(data-testid="logs-tab-audit")
    end

    test "the old audit address leads to the audit kind, keeping its query", %{conn: conn} do
      assert redirected_to(get(conn, "/audit?name=relay_start")) ==
               "/logs/audit?name=relay_start"

      assert redirected_to(get(conn, "/audit")) == "/logs/audit"
    end
  end

  describe "filters" do
    test "typing reads nothing until Read, which carries the filters in the address", %{
      conn: conn,
      node: node
    } do
      {view, _html} = live_loaded(conn, ~p"/logs/audit")
      before = length(reads(node))

      type_filters(view, %{"source" => "cli"})
      assert length(reads(node)) == before

      submit_filters(view, %{"name" => "relay_start"})
      query = view |> assert_patch() |> query_of()

      assert query["source"] == "cli"
      assert query["name"] == "relay_start"
      assert last_read(node)[:filters] == %{"source" => "cli", "name" => "relay_start"}
    end

    test "a link with a filter opens the view it names", %{conn: conn, node: node} do
      {_view, _html} = live_loaded(conn, ~p"/logs/relay_history?relay=fan_trade-7f3a")

      params = last_read(node)
      assert params[:kind] == "relay_history"
      assert params[:filters] == %{"relay" => "fan_trade-7f3a"}
    end

    test "a filter the kind does not declare is dropped, not sent on", %{
      conn: conn,
      node: node
    } do
      {_view, _html} = live_loaded(conn, ~p"/logs/audit?factory=x&name=start&limit=nope")

      params = last_read(node)
      assert params[:filters] == %{"name" => "start"}
      assert params[:limit] == 100
    end

    test "the time range is read as UTC", %{conn: conn, node: node} do
      {_view, _html} = live_loaded(conn, "/logs/audit?since=2026-10-29T10:00")

      assert last_read(node)[:since_us] ==
               DateTime.to_unix(~U[2026-10-29 10:00:00Z], :microsecond)
    end
  end

  describe "reading" do
    test "records are listed newest first as the controller answered", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Logs, :read}, FakeController.log_page([audited(2), audited(1)]))

      {_view, html} = live_loaded(conn, ~p"/logs/audit")

      assert length(testids(html, ~s([data-testid="logs-records"] [data-testid="log-record"]))) ==
               2

      assert text_of(html, ~s([data-testid="logs-records"] li:first-child)) =~ "start_2"
      refute html =~ ~s(data-testid="logs-truncated")
    end

    test "nothing matching says so", %{conn: conn} do
      {_view, html} = live_loaded(conn, ~p"/logs/audit")

      assert text_of(html, testid("logs-records-empty")) =~ "No record matches this filter."
    end

    test "Read more reads the next older records by the answer's cursor", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Logs, :read},
        FakeController.log_page([audited(3), audited(2)], "c1")
      )

      {view, _html} = live_loaded(conn, ~p"/logs/audit?name=start")

      FakeController.set(node, {Logs, :read}, FakeController.log_page([audited(1)]))
      html = view |> element(~s([data-testid="logs-read-more"])) |> render_click()

      params = last_read(node)
      assert params[:before] == "c1"
      assert params[:filters] == %{"name" => "start"}

      assert length(testids(html, ~s([data-testid="logs-records"] [data-testid="log-record"]))) ==
               3

      assert text_of(html, ~s([data-testid="logs-records"] li:last-child)) =~ "start_1"
      refute html =~ ~s(data-testid="logs-read-more")
    end

    test "Read more stops at the cap and says to narrow the filter", %{conn: conn, node: node} do
      page = for n <- 1..1_000, do: audited(n)
      FakeController.set(node, {Logs, :read}, FakeController.log_page(page, "more"))

      {view, _html} = live_loaded(conn, ~p"/logs/audit?limit=1000")
      for _ <- 1..4, do: click(view, testid("logs-read-more"))

      html = render(view)

      assert length(testids(html, ~s([data-testid="logs-records"] [data-testid="log-record"]))) ==
               5_000

      assert text_of(html, testid("logs-capped")) =~ "read past the first 5000"
      refute has_element?(view, testid("logs-read-more"))
      # The logs service answers at most 1000 records to one read.
      assert last_read(node)[:limit] == 1_000
    end

    test "a Read more the controller refuses keeps the records already shown", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Logs, :read},
        FakeController.log_page([audited(2), audited(1)], "c1")
      )

      {view, _html} = live_loaded(conn, ~p"/logs/audit")

      FakeController.set(node, {Logs, :read}, FakeController.error("controller.timeout"))
      html = click(view, testid("logs-read-more"))

      assert html =~ "controller.timeout"

      assert length(testids(html, ~s([data-testid="logs-records"] [data-testid="log-record"]))) ==
               2

      assert html =~ ~s(data-testid="logs-read-more")
    end

    test "an unbound principal is a refusal with the remedy, not an empty log", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Logs, :read},
        FakeController.error(
          "authz.principal_not_bound",
          "the call carries no verifiable identity"
        )
      )

      {_view, html} = live_loaded(conn, ~p"/logs/audit")

      assert html =~ "the call carries no verifiable identity"
      assert html =~ ~s(<code data-testid="runtime-error-code">authz.principal_not_bound</code>)
      assert html =~ ~s(href="/users/settings")
      refute html =~ ~s(data-testid="logs-records-empty")
    end

    test "another refusal names its code and links nowhere", %{conn: conn, node: node} do
      FakeController.set(node, {Logs, :read}, FakeController.error("authz.role_insufficient"))

      {view, html} = live_loaded(conn, ~p"/logs/audit")

      assert html =~ "authz.role_insufficient"
      refute html =~ ~s(data-testid="logs-records-empty")
      refute view |> element(testid("runtime-error")) |> render() =~ ~s(href="/users/settings")
    end

    test "a controller that did not answer is named beside what the others answered", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Logs, :read},
        FakeController.log_page([audited(1)], nil, ["flezha@c2"])
      )

      {_view, html} = live_loaded(conn, ~p"/logs/audit")

      assert text_of(html, testid("partial-answer")) =~ "flezha@c2 did not"
      assert html =~ ~s(data-testid="log-record")
    end
  end

  describe "a switched-off log" do
    test "names the setting that turns it on, while another kind still reads", %{
      conn: conn,
      node: node
    } do
      off =
        FakeController.error(
          "audit.disabled",
          "the audit log is disabled; enable it with FLEZHA_AUDIT_ENABLED=true"
        )

      FakeController.set(
        node,
        {Logs, :files},
        {:per_arg, {0, :kind}, %{"audit" => off}, files([])}
      )

      history =
        FakeController.history_record("fan_trade-7f3a", %{"factory" => "fan_trade"})

      FakeController.set(
        node,
        {Logs, :read},
        {:per_arg, {0, :kind}, %{"relay_history" => FakeController.log_page([history])},
         FakeController.log_page([])}
      )

      {view, html} = live_loaded(conn, ~p"/logs/audit")

      assert text_of(html, testid("logs-disabled")) =~
               "The audit log is disabled; enable it with FLEZHA_AUDIT_ENABLED=true."

      refute html =~ ~s(data-testid="logs-records-panel")

      html = click(view, testid("logs-tab-relay_history"))
      assert_patch(view, ~p"/logs/relay_history")

      refute html =~ ~s(data-testid="logs-disabled")
      assert text_of(html, testid("log-record-sentence")) =~ "fan_trade-7f3a started"
    end

    test "observability being off names its own flag", %{conn: conn, node: node} do
      FakeController.set(node, {Logs, :files}, FakeController.error("observability.disabled"))

      {_view, html} = live_loaded(conn, ~p"/logs/audit")

      assert text_of(html, testid("logs-disabled")) =~ "FLEZHA_OBSERVABILITY_ENABLED"
    end

    test "another failure is an error, not a switched-off log", %{conn: conn, node: node} do
      FakeController.set(node, {Logs, :files}, FakeController.error("controller.timeout"))

      {_view, html} = live_loaded(conn, ~p"/logs/audit")

      refute html =~ ~s(data-testid="logs-disabled")
      assert html =~ "controller.timeout (test)"
    end
  end

  describe "files per controller" do
    @current "storage/app/audit/audit-current.jsonl"

    setup %{node: node} do
      FakeController.set(
        node,
        {Logs, :stats},
        stats([
          FakeController.log_stats_row(:flezha@c2, %{current_file: @current, record_count: 5}),
          FakeController.log_stats_row(:flezha@c1, %{
            current_file: @current,
            record_count: 42,
            current_file_bytes: 4_096,
            total_bytes: 2_048
          })
        ])
      )

      FakeController.set(
        node,
        {Logs, :files},
        files([
          FakeController.log_file_row(:flezha@c2, "audit-2.jsonl"),
          FakeController.log_file_row(:flezha@c1, "audit-1.jsonl", %{record_count: 7})
        ])
      )

      :ok
    end

    test "every controller's current file comes first, then the rotated ones", %{conn: conn} do
      {_view, html} = live_loaded(conn, ~p"/logs/audit")

      ids =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#logs-file-rows tr")
        |> LazyHTML.attribute("id")

      assert ids == [
               "logs-file-flezha@c1-audit-current.jsonl",
               "logs-file-flezha@c2-audit-current.jsonl",
               "logs-file-flezha@c1-audit-1.jsonl",
               "logs-file-flezha@c2-audit-2.jsonl"
             ]

      current = text_of(html, ~s([id="logs-file-flezha@c1-audit-current.jsonl"]))
      assert current =~ "audit-current.jsonl current"
      assert current =~ "4.0 KB"
      assert text_of(html, ~s([id="logs-file-flezha@c1-audit-1.jsonl"])) =~ ~r/\b7\b/
      assert text_of(html, testid("logs-stats-flezha@c1")) =~ "42"
      assert text_of(html, testid("logs-stats-flezha@c1")) =~ "2.0 KB"
      refute html =~ "sha256"
    end

    test "Rotate closes that controller's file and lists it after a reload", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Logs, :rotate},
        {:ok, %{rotated: [%{node: :flezha@c2, rotated_to: "audit-3.jsonl"}], unreachable: []}}
      )

      {view, _html} = live_loaded(conn, ~p"/logs/audit")

      FakeController.set(
        node,
        {Logs, :files},
        files([FakeController.log_file_row(:flezha@c2, "audit-3.jsonl")])
      )

      html = click(view, testid("logs-rotate-flezha@c2"))

      assert [[[kind: "audit", node: "flezha@c2"], _ctx]] =
               FakeController.calls(node, {Logs, :rotate})

      assert html =~ "audit-3.jsonl"
      assert html =~ "flezha@c2 started a new file"
    end

    test "a refused rotation is shown and leaves the listing as it was", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Logs, :rotate},
        FakeController.error("authz.role_insufficient", "viewer may not rotate a log")
      )

      {view, _html} = live_loaded(conn, ~p"/logs/audit")
      files_before = length(FakeController.calls(node, {Logs, :files}))

      html = click(view, testid("logs-rotate-flezha@c1"))

      assert text_of(html, testid("logs-rotate-error")) =~ "viewer may not rotate a log"
      assert length(FakeController.calls(node, {Logs, :files})) == files_before
    end

    test "without the rotate call no file offers Rotate", %{conn: conn, node: node, user: user} do
      identity = %{principal: "x@default", namespace: "default", role: :viewer}
      enforce_operations(node, user, identity)
      grant_operations(node, identity, ~w(Logs.kinds Logs.files Logs.stats Logs.read))

      {view, _html} = live_loaded(conn, ~p"/logs/audit")

      assert has_element?(view, testid("logs-file-current"))
      refute has_element?(view, ~s([data-testid^="logs-rotate-"]))
    end
  end

  describe "a record" do
    test "opens to the whole record and folds again", %{conn: conn, node: node} do
      FakeController.set(node, {Logs, :read}, FakeController.log_page([audited(1), audited(2)]))
      {view, _html} = live_loaded(conn, ~p"/logs/audit")

      first = ~s([data-testid="logs-records"] li:first-child [data-testid="log-record-head"])
      assert text_of(render(view), first) =~ ~r/Open$/

      html = view |> element(~s(li:first-child [data-testid="log-record-head"])) |> render_click()

      assert text_of(html, testid("log-record-json")) =~ ~s("seq": 1)
      assert has_element?(view, first <> ~s([aria-expanded="true"]))
      assert text_of(html, first) =~ ~r/Close$/

      html = click(view, first)
      refute html =~ ~s(data-testid="log-record-json")
      assert text_of(html, first) =~ ~r/Open$/
    end

    test "a relay history record reads as its sentence", %{conn: conn, node: node} do
      ended =
        FakeController.history_record("fan_trade-7f3a", %{
          "event" => "ended",
          "factory" => "fan_trade",
          "outcome" => "undone",
          "duration_ms" => 41_000,
          "halted" => false,
          "error" => "",
          "origin" => %{"kind" => "spawn", "parent_relay" => "ma_fan"}
        })

      FakeController.set(node, {Logs, :read}, FakeController.log_page([ended]))

      {_view, html} = live_loaded(conn, ~p"/logs/relay_history")

      assert text_of(html, testid("log-record-sentence")) ==
               "fan_trade-7f3a finished: undone after 41 s, spawned by ma_fan"

      assert html =~ ~s(href="/namespaces/default/relays/ma_fan")
      assert text_of(html, ~s([data-testid="log-record-head"])) =~ "flezha@node-a"
    end
  end

  describe "the tail" do
    test "starts paused, so an idle tab holds no subscription", %{conn: conn, node: node} do
      {_view, html} = live_loaded(conn, ~p"/logs/audit")

      assert html =~ ~s(data-testid="logs-tail-idle")
      assert FakeController.streams(node, @tail) == []
    end

    test "carries the applied filters and shows what the controller forwards", %{
      conn: conn,
      node: node
    } do
      {view, _html} = live_loaded(conn, ~p"/logs/audit?name=start_7")
      start_tail(view)

      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) != [] end)

      # The controller narrows the tail: what it is asked for is what it forwards.
      assert [[[kind: "audit", filters: %{"name" => "start_7"}], %{source: :ui, emit: emit}]] =
               FakeController.calls(node, @tail)

      assert is_pid(emit)

      tail = ~s([data-testid="logs-tail-records"] [data-testid="log-record"])
      shown = fn -> view |> render() |> testids(tail) |> length() end

      FakeController.emit(node, @tail, audited(7))
      # A second record is the barrier: once it shows, the first has been handled.
      FakeController.emit(node, @tail, audited(8, %{"name" => "start_7", "source" => "cli"}))

      assert PeerNode.eventually(fn -> shown.() == 2 end)

      html = render(view)
      assert text_of(html, ~s([data-testid="logs-tail-records"] li:first-child)) =~ "cli"
      assert text_of(html, ~s([data-testid="logs-tail-records"] li:last-child)) =~ "start_7"
    end

    test "a changed filter reopens the running tail with it", %{conn: conn, node: node} do
      {view, _html} = live_loaded(conn, ~p"/logs/audit")
      start_tail(view)
      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) != [] end)

      submit_filters(view, %{"source" => "cli"})
      assert_patch(view)

      assert PeerNode.eventually(fn ->
               match?(
                 [[[kind: "audit", filters: %{"source" => "cli"}], _ctx] | _],
                 Enum.reverse(FakeController.calls(node, @tail))
               )
             end)
    end

    test "switching kind stops the feed", %{conn: conn, node: node} do
      {view, _html} = live_loaded(conn, ~p"/logs/audit")
      start_tail(view)
      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) != [] end)

      click(view, testid("logs-tab-relay_history"))
      assert_patch(view, ~p"/logs/relay_history")

      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) == [] end)
      assert has_element?(view, testid("logs-tail-idle"))
    end

    test "stopping it ends the controller's stream", %{conn: conn, node: node} do
      {view, _html} = live_loaded(conn, ~p"/logs/audit")
      start_tail(view)
      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) != [] end)

      start_tail(view)

      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) == [] end)
    end

    test "a refused tail is stated, and the reads still work", %{conn: conn, node: node} do
      FakeController.set(node, @tail, FakeController.error("authz.role_insufficient"))
      FakeController.set(node, {Logs, :read}, FakeController.log_page([audited(1)]))

      {view, _html} = live_loaded(conn, ~p"/logs/audit")
      start_tail(view)

      assert PeerNode.eventually(fn -> render(view) =~ "authz.role_insufficient" end)
      assert render(view) =~ "the live tail"

      submit_filters(view, %{"name" => "start_1"})
      assert_patch(view)
      assert render(view) =~ ~s(data-testid="log-record")
    end
  end
end
