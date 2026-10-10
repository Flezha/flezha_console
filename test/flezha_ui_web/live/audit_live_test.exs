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

      assert html =~ ~s(data-testid="audit-stats")
      assert html =~ "42"
      assert html =~ ~s(data-testid="audit-files")
      assert html =~ "audit-1.log"
      assert html =~ "7 records"
      assert html =~ "2.0 KB"
      refute html =~ "sha256"
    end

    test "explains an empty catalog rather than looking broken", %{conn: conn, node: node} do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, []})
      FakeController.set(node, {AuditLog, :stats}, {:ok, %{current_file: "audit-now.log"}})

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ ~s(data-testid="audit-files-empty")
      assert html =~ "No file has been rotated yet"
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
      html = render_click(view, "read", %{})

      assert html =~ ~s(data-testid="audit-records")
      assert html =~ "audit_read"
      refute html =~ ~s(data-testid="audit-truncated")
    end

    test "reports when nothing matched", %{conn: conn, node: node} do
      FakeController.set(node, {AuditLog, :read}, {:ok, []})

      {:ok, view, _html} = live(conn, ~p"/audit")

      assert render_click(view, "read", %{}) =~ ~s(data-testid="audit-records-empty")
    end

    test "says so when the limit cut the result off", %{conn: conn, node: node} do
      # The screen asks for limit + 1; getting it back is how it knows.
      FakeController.set(node, {AuditLog, :read}, {:ok, Enum.map(1..3, &record/1)})

      {:ok, view, _html} = live(conn, ~p"/audit")
      render_change(view, "filter_change", %{"filter" => %{"limit" => "2"}})
      html = render_click(view, "read", %{})

      assert html =~ ~s(data-testid="audit-truncated")
      assert html =~ "More records matched"
    end

    test "asks for one more than the limit, so truncation is detectable", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/audit")
      render_change(view, "filter_change", %{"filter" => %{"limit" => "25"}})
      render_click(view, "read", %{})

      assert [%{limit: 26}, %{source: :ui}] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()
    end

    test "passes the filter down rather than filtering locally", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      render_change(view, "filter_change", %{
        "filter" => %{"source" => "cli", "name" => "relay_start"}
      })

      render_click(view, "read", %{})

      assert [%{source: "cli", name: "relay_start"}, _ctx] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()
    end

    test "an out-of-range limit falls back rather than being sent on", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/audit")
      render_change(view, "filter_change", %{"filter" => %{"limit" => "not a number"}})
      render_click(view, "read", %{})

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
      html = render_click(view, "read", %{})

      # The controller's own message and code, with the remedy linked.
      assert html =~ "refused this audit read"
      assert html =~ "the call carries no verifiable identity (authz.principal_not_bound)"
      assert html =~ ~s(href="/users/settings")
    end

    test "a refusal for another reason names its code and links nowhere", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {AuditLog, :read}, FakeController.error("authz.role_insufficient"))

      {:ok, view, _html} = live(conn, ~p"/audit")
      html = render_click(view, "read", %{})

      assert html =~ "authz.role_insufficient"
      refute html =~ ~s(data-testid="audit-records-empty")

      refute view |> element(~s([data-testid="runtime-error"])) |> render() =~
               ~s(href="/users/settings")
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
      assert html =~ "Start tail"
      assert FakeController.streams(node, @tail) == []
    end

    test "a started tail shows records as the controller forwards them", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/audit")
      render_click(view, "start_tail", %{})

      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) != [] end)
      assert [[[], %{source: :ui, emit: emit}]] = FakeController.calls(node, @tail)
      assert is_pid(emit)

      FakeController.emit(node, @tail, record(7))

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="audit-tail-records") end)
      assert render(view) =~ "audit_read"
    end

    test "stopping the tail ends the controller's stream", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/audit")
      render_click(view, "start_tail", %{})
      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) != [] end)

      render_click(view, "stop_tail", %{})

      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) == [] end)
    end

    test "leaving the screen ends the controller's stream", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/audit")
      render_click(view, "start_tail", %{})
      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) != [] end)

      # The screen dies without saying goodbye; its feed goes with it.
      Process.flag(:trap_exit, true)
      Process.exit(view.pid, :kill)

      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) == [] end)
    end

    test "a refused tail is stated, and the reads still work", %{conn: conn, node: node} do
      FakeController.set(node, @tail, FakeController.error("authz.role_insufficient"))
      FakeController.set(node, {AuditLog, :read}, {:ok, [record(1)]})

      {:ok, view, _html} = live(conn, ~p"/audit")
      render_click(view, "start_tail", %{})

      assert PeerNode.eventually(fn -> render(view) =~ "authz.role_insufficient" end)
      assert render(view) =~ "refused the live audit tail"
      assert render_click(view, "read", %{}) =~ ~s(data-testid="audit-records")
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
