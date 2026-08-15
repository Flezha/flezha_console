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
      FakeController.set(node, {AuditLog, :list_files}, {:error, :audit_log_disabled})

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ ~s(data-testid="audit-disabled")
      assert html =~ "FLEZHA_AUDIT_ENABLED"
      refute html =~ ~s(data-testid="audit-stats")
    end

    test "names the flag that turns observability on", %{conn: conn, node: node} do
      FakeController.set(node, {AuditLog, :list_files}, {:error, :observability_disabled})

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ ~s(data-testid="audit-disabled")
      assert html =~ "FLEZHA_OBSERVABILITY_ENABLED"
    end

    test "a transport failure is reported as an error, not as being switched off", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {AuditLog, :list_files}, {:error, :timeout})

      {:ok, _view, html} = live(conn, ~p"/audit")

      refute html =~ ~s(data-testid="audit-disabled")
      assert html =~ "The flezha controller did not answer in time."
    end
  end

  describe "the catalog" do
    test "renders the statistics the controller reports", %{conn: conn, node: node} do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, ["audit-1.log"]})

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

      assert [%{limit: 26}] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()
    end

    test "passes the filter down rather than filtering locally", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      render_change(view, "filter_change", %{
        "filter" => %{"source" => "cli", "name" => "operative_start"}
      })

      render_click(view, "read", %{})

      assert [%{source: "cli", name: "operative_start"}] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()
    end

    test "an out-of-range limit falls back rather than being sent on", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/audit")
      render_change(view, "filter_change", %{"filter" => %{"limit" => "not a number"}})
      render_click(view, "read", %{})

      assert [%{limit: 101}] =
               node |> FakeController.calls({AuditLog, :read}) |> List.last()
    end

    test "explains a refusal caused by configuration, not by malfunction", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {AuditLog, :read},
        {:error, {:forbidden, :principal_not_bound}}
      )

      {:ok, view, _html} = live(conn, ~p"/audit")

      assert render_click(view, "read", %{}) =~
               "Authorization is enabled on the controller and this UI has no bound principal."
    end
  end

  describe "the tail" do
    setup %{node: node} do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, []})
      :ok
    end

    test "starts paused, so an idle tab holds no subscription", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ ~s(data-testid="audit-tail-idle")
      assert html =~ "Start tail"
    end
  end
end
