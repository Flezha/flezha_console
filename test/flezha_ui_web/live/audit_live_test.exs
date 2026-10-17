defmodule FlezhaUiWeb.AuditLiveTest do
  @moduledoc """
  The audit log screen, against a controller whose audit subsystem can be
  switched off.

  The dev stack sets `FLEZHA_AUDIT_ENABLED=true`, so the browser suite asserts
  the enabled path unconditionally. The states covered here — the subsystem
  refusing, a read the controller forbids, a filter matching nothing — are the
  ones a live controller will not produce on request.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.AuditLog

  defp record(n), do: %{"source" => "ui", "name" => "audit_read", "seq" => n}

  defp read(view), do: view |> element(~s([data-testid="audit-read-btn"])) |> render_click()

  defp filter(view, fields) do
    view
    |> form(~s(form[phx-change="filter_change"]), %{"filter" => fields})
    |> render_change()
  end

  defp start_tail(view),
    do: view |> element(~s([data-testid="audit-tail-toggle"])) |> render_click()

  describe "when the subsystem is off" do
    test "names the flag that turns audit logging on", %{conn: conn, node: node} do
      FakeController.set(node, {AuditLog, :list_files}, FakeController.error("audit.disabled"))

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ ~s(data-testid="audit-disabled")
      assert html =~ "FLEZHA_AUDIT_ENABLED"
      refute html =~ ~s(data-testid="audit-stats")
    end

    test "names the flag that turns observability on", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {AuditLog, :list_files},
        FakeController.error("observability.disabled")
      )

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ ~s(data-testid="audit-disabled")
      assert html =~ "FLEZHA_OBSERVABILITY_ENABLED"
    end

    test "another failure is reported as an error, not as being switched off", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {AuditLog, :list_files},
        FakeController.error("controller.timeout")
      )

      {:ok, _view, html} = live(conn, ~p"/audit")

      refute html =~ ~s(data-testid="audit-disabled")
      assert html =~ ~s(data-testid="runtime-error")
      assert html =~ "controller.timeout (test)"
    end
  end

  describe "the catalog" do
    test "renders the statistics the controller reports", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {AuditLog, :list_files},
        {:ok, [%{filename: "audit-1.log", record_count: 7, size_bytes: 2048, sha256: "ab"}]}
      )

      FakeController.set(
        node,
        {AuditLog, :stats},
        {:ok, %{record_count: 42, total_files: 3, total_bytes: 2048, fsync_mode: :always}}
      )

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ "42"
      assert html =~ "audit-1.log"
      assert html =~ ~r/<td[^>]*>\s*7\s*<\/td>/
      assert html =~ "2.0 KB"
      refute html =~ "sha256"
    end

    test "explains an empty catalog rather than looking broken", %{conn: conn, node: node} do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, []})
      FakeController.set(node, {AuditLog, :stats}, {:ok, %{current_file: "audit-now.log"}})

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ ~s(data-testid="audit-files-empty")
      assert html =~ "None has been rotated yet"
      assert html =~ "audit-now.log"
    end
  end

  describe "reading records" do
    setup %{node: node} do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, []})
      :ok
    end

    test "renders the records the controller returned", %{conn: conn, node: node} do
      FakeController.set(node, {AuditLog, :read}, {:ok, [record(1), record(2)]})

      {:ok, view, _html} = live(conn, ~p"/audit")
      html = read(view)

      assert html =~ ~s(data-testid="audit-records")
      assert html =~ "audit_read"
      refute html =~ ~s(data-testid="audit-truncated")
    end

    test "reports when nothing matched", %{conn: conn, node: node} do
      FakeController.set(node, {AuditLog, :read}, {:ok, []})

      {:ok, view, _html} = live(conn, ~p"/audit")

      assert read(view) =~ ~s(data-testid="audit-records-empty")
    end

    test "says so when the limit cut the result off", %{conn: conn, node: node} do
      # The screen asks for limit + 1; getting it back is how it knows.
      FakeController.set(node, {AuditLog, :read}, {:ok, Enum.map(1..3, &record/1)})

      {:ok, view, _html} = live(conn, ~p"/audit")
      filter(view, %{"limit" => "2"})
      html = read(view)

      assert html =~ ~s(data-testid="audit-truncated")
      assert html =~ "More records match than this read took"
    end

    test "asks for one more than the limit, so truncation is detectable", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/audit")
      filter(view, %{"limit" => "25"})
      read(view)

      assert [%{limit: 26}, %{source: :ui}] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()
    end

    test "passes the filter down rather than filtering locally", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      filter(view, %{"source" => "cli", "name" => "relay_start"})

      read(view)

      assert [%{source: "cli", name: "relay_start"}, _ctx] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()
    end

    test "an out-of-range limit falls back rather than being sent on", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/audit")
      filter(view, %{"limit" => "not a number"})
      read(view)

      assert [%{limit: 101}, _ctx] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()
    end

    test "explains a refusal caused by configuration, not by malfunction", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {AuditLog, :read},
        FakeController.error(
          "authz.principal_not_bound",
          "the call carries no verifiable identity"
        )
      )

      {:ok, view, _html} = live(conn, ~p"/audit")
      html = read(view)

      # The controller's own message and code, with the remedy linked.
      assert html =~ "refused this audit read"
      assert html =~ "the call carries no verifiable identity"
      assert html =~ ~s(<code data-testid="runtime-error-code">authz.principal_not_bound</code>)
      assert html =~ ~s(href="/users/settings")
    end

    test "a refusal for another reason names its code and links nowhere", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {AuditLog, :read}, FakeController.error("authz.role_insufficient"))

      {:ok, view, _html} = live(conn, ~p"/audit")
      html = read(view)

      assert html =~ "authz.role_insufficient"
      refute html =~ ~s(data-testid="audit-records-empty")

      refute view |> element(~s([data-testid="runtime-error"])) |> render() =~
               ~s(href="/users/settings")
    end
  end

  describe "opening a file" do
    @rotated %{filename: "audit-1.jsonl", record_count: 7, size_bytes: 2048, sha256: "ab"}

    setup %{node: node} do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, [@rotated]})

      FakeController.set(
        node,
        {AuditLog, :stats},
        {:ok,
         %{
           current_file: "app_data/audit/audit-current.jsonl",
           record_count: 12,
           current_file_bytes: 4096
         }}
      )

      :ok
    end

    defp open(view, testid),
      do: view |> element(~s([data-testid="#{testid}"])) |> render_click()

    test "the file being written is listed first, by its name, with its count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/audit")

      assert text_of(html, ~s([data-testid="audit-file-current"])) =~
               "audit-current.jsonl current"

      assert text_of(html, ~s([data-testid="audit-file-current"])) =~ "12"
      assert text_of(html, ~s([data-testid="audit-file-current"])) =~ "4.0 KB"
      assert :binary.match(html, "audit-file-current") < :binary.match(html, ~s("audit-file"))
    end

    test "opening a rotated file reads it, keeping the rest of the filter", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {AuditLog, :read}, {:ok, [record(1)]})
      {:ok, view, _html} = live(conn, ~p"/audit")
      filter(view, %{"source" => "cli"})

      html = open(view, "audit-open-audit-1.jsonl")

      assert [%{file: "audit-1.jsonl", source: "cli"}, _ctx] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()

      assert html =~ ~s(data-testid="audit-record")
      assert has_element?(view, ~s(input[name="filter[file]"][value="audit-1.jsonl"]))
      assert_push_event(view, "fui:reveal", %{id: "audit-records"})
    end

    test "the current file opens by its name alone", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/audit")
      open(view, "audit-open-audit-current.jsonl")

      assert [%{file: "audit-current.jsonl"}, _ctx] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()
    end

    test "without the read nothing in the catalog opens", %{conn: conn, node: node, user: user} do
      identity = %{principal: "x@default", namespace: "default", role: :viewer}
      enforce_operations(node, user, identity)
      grant_operations(node, identity, ["AuditLog.list_files", "AuditLog.stats"])

      {:ok, view, _html} = live(conn, ~p"/audit")

      assert has_element?(view, ~s([data-testid="audit-file"]))
      refute has_element?(view, ~s([data-testid^="audit-open-"]))
    end

    test "a forged open of a file the catalog does not list reads nothing", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/audit")
      render_click(view, "open_file", %{"file" => "../../etc/passwd"})

      assert FakeController.calls(node, {AuditLog, :read}) == []
    end
  end

  describe "a read record" do
    setup %{node: node} do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, []})
      :ok
    end

    defp audited(n, ts, overrides \\ %{}) do
      Map.merge(
        %{
          "ts_us" => ts,
          "ts_iso" => "2026-10-17T10:00:0#{n}.000Z",
          "source" => "relay_service",
          "name" => "start",
          "metadata" => %{"outcome" => "ok", "seq" => n},
          "caller" => %{"principal" => "alice@default"}
        },
        overrides
      )
    end

    test "reads as one line of when, where, what, who and outcome, and opens to the whole", %{
      conn: conn,
      node: node
    } do
      denied =
        audited(2, 20, %{
          "name" => "authorization_denied",
          "metadata" => %{"reason" => "authz.role_insufficient"}
        })

      FakeController.set(node, {AuditLog, :read}, {:ok, [audited(1, 10), denied]})
      {:ok, view, _html} = live(conn, ~p"/audit")
      html = read(view)

      row = text_of(html, ~s([data-testid="audit-record-0"]))

      for part <- ~w(2026-10-17T10:00:01.000Z relay_service start alice@default ok),
          do: assert(row =~ part)

      assert text_of(html, ~s([data-testid="audit-record-1"])) =~ "authz.role_insufficient"

      html = view |> element(~s([data-testid="audit-record-0"])) |> render_click()
      assert text_of(html, ~s([data-testid="audit-record-json-0"])) =~ ~s("seq": 1)

      html = view |> element(~s([data-testid="audit-record-0"])) |> render_click()
      refute html =~ ~s(data-testid="audit-record-json-0")
    end

    test "Read more reads on past the records shown, by position, with the read's own filter",
         %{conn: conn, node: node} do
      # Timestamps are a VM's monotonic clock, so a restart makes them run
      # backwards in one file: position is the order.
      file = [audited(1, 50), audited(2, 60), audited(3, 5), audited(4, 6)]
      FakeController.set(node, {AuditLog, :read}, {:ok, Enum.take(file, 3)})

      {:ok, view, _html} = live(conn, ~p"/audit")
      filter(view, %{"limit" => "2"})
      read(view)

      # A filter edited after the read does not leak into reading on.
      filter(view, %{"source" => "cli"})
      FakeController.set(node, {AuditLog, :read}, {:ok, file})
      html = view |> element(~s([data-testid="audit-read-more"])) |> render_click()

      assert [%{limit: 5} = params, _ctx] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()

      refute Map.has_key?(params, :since_us)
      refute Map.has_key?(params, :source)

      seqs = for i <- 0..3, do: text_of(html, ~s([data-testid="audit-record-#{i}"]))

      assert Enum.map(seqs, &String.slice(&1, 0, 24)) ==
               Enum.map(1..4, &"2026-10-17T10:00:0#{&1}.000Z")

      refute html =~ ~s(data-testid="audit-record-4")
      refute html =~ ~s(data-testid="audit-read-more")
    end
  end

  describe "the tail" do
    @tail {AuditLog, :tail}

    setup %{node: node} do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, []})
      :ok
    end

    test "starts paused, so an idle tab holds no subscription", %{conn: conn, node: node} do
      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ ~s(data-testid="audit-tail-idle")
      assert html =~ "Tail new records"
      assert FakeController.streams(node, @tail) == []
    end

    test "a started tail shows records as the controller forwards them", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/audit")
      start_tail(view)

      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) != [] end)
      assert [[[], %{source: :ui, emit: emit}]] = FakeController.calls(node, @tail)
      assert is_pid(emit)

      FakeController.emit(node, @tail, record(7))

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="audit-tail-records") end)
      assert render(view) =~ "audit_read"
    end

    test "a refused tail is stated, and the reads still work", %{conn: conn, node: node} do
      FakeController.set(node, @tail, FakeController.error("authz.role_insufficient"))
      FakeController.set(node, {AuditLog, :read}, {:ok, [record(1)]})

      {:ok, view, _html} = live(conn, ~p"/audit")
      start_tail(view)

      assert PeerNode.eventually(fn -> render(view) =~ "authz.role_insufficient" end)
      assert render(view) =~ "refused the live audit tail"
      assert read(view) =~ ~s(data-testid="audit-records")
    end
  end

  describe "rotating the audit log" do
    test "rotates and reloads the catalog, which lists the closed file", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, []})
      {:ok, view, _html} = live(conn, ~p"/audit")

      closed = %{filename: "audit-20261006T120000.jsonl", size_bytes: 512, record_count: 3}
      FakeController.set(node, {AuditLog, :list_files}, {:ok, [closed]})

      html = view |> element(~s([data-testid="audit-rotate-btn"])) |> render_click()

      assert [[_ctx]] = FakeController.calls(node, {AuditLog, :rotate})
      assert html =~ "audit-20261006T120000.jsonl"
      assert html =~ "Audit log rotated"
    end

    test "a refused rotation shows the error and leaves the catalog as it was", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, []})

      FakeController.set(
        node,
        {AuditLog, :rotate},
        FakeController.error("authz.role_insufficient", "viewer may not rotate the audit log")
      )

      {:ok, view, _html} = live(conn, ~p"/audit")
      files_before = length(FakeController.calls(node, {AuditLog, :list_files}))

      html = view |> element(~s([data-testid="audit-rotate-btn"])) |> render_click()

      assert html =~ ~s(data-testid="audit-rotate-error")
      assert html =~ "viewer may not rotate the audit log"
      assert length(FakeController.calls(node, {AuditLog, :list_files})) == files_before
    end
  end
end
