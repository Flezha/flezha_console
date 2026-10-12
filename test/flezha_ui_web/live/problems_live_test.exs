defmodule FlezhaUiWeb.ProblemsLiveTest do
  @moduledoc """
  The open problems screen: what the shell's pulse gathered across every
  reachable namespace, worst first, each with why and the action that fixes
  it — and Home's own share of the same list.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Relay

  defp fleet(node, rows),
    do: FakeController.set_fleet(node, namespaces: ["default"], rows: %{"default" => rows})

  defp row(id, health), do: FakeController.relay_row(id, %{health: health})

  defp item_ids(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([data-testid^="problem-relay:"]))
    |> LazyHTML.attribute("data-testid")
  end

  test "says nothing before the pulse has run", %{conn: conn, node: node} do
    fleet(node, [row("relay_s", :suspended)])

    {:ok, _view, html} = live(conn, ~p"/problems")

    assert html =~ ~s(data-testid="problems-loading")
    refute html =~ ~s(data-testid="problems-clear")
  end

  test "lists every problem worst first, each with why and its fix", %{conn: conn, node: node} do
    fleet(node, [row("relay_s", :suspended), row("relay_f", :failed)])

    {:ok, view, _html} = live(conn, ~p"/problems")
    html = render(view)

    assert item_ids(html) == ["problem-relay:default:relay_f", "problem-relay:default:relay_s"]

    assert view |> element(~s([data-testid="problem-why-relay:default:relay_s"])) |> render() =~
             "suspended"

    assert has_element?(
             view,
             ~s(a[data-testid="problem-open-relay:default:relay_s"][href="/namespaces/default/relays/relay_s"])
           )
  end

  test "diagnosis answers beneath its problem", %{conn: conn, node: node} do
    fleet(node, [row("relay_s", :suspended)])

    {:ok, view, _html} = live(conn, ~p"/problems")
    render(view)

    assert view
           |> element(~s([data-testid="problem-diagnose-relay:default:relay_s"]))
           |> render_click() =~ ~s(data-testid="problem-diagnosis-relay:default:relay_s")

    assert [["default", "relay_s", _ctx]] = FakeController.calls(node, {Relay, :diagnose})
  end

  test "a problem that resolves leaves on the next pulse", %{conn: conn, node: node} do
    fleet(node, [row("relay_s", :suspended)])

    {:ok, view, _html} = live(conn, ~p"/problems")
    assert render(view) =~ ~s(data-testid="problem-relay:default:relay_s")

    fleet(node, [row("relay_s", :healthy)])
    send(view.pid, :shell_pulse)

    html = render(view)
    refute html =~ ~s(data-testid="problem-relay:default:relay_s")
    assert html =~ ~s(data-testid="problems-clear")
    assert html =~ "All clear"
  end

  test "Home shows its first three and links to the rest", %{conn: conn, node: node} do
    fleet(node, Enum.map(1..5, &row("relay_#{&1}", :suspended)))

    {:ok, view, _html} = live(conn, ~p"/namespaces/default")
    html = render(view)

    assert length(item_ids(html)) == 3

    assert view |> element(~s(a[data-testid="problems-more"][href="/problems"])) |> render() =~
             "2 more problems"
  end
end
