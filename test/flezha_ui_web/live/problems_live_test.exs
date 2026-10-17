defmodule FlezhaUiWeb.ProblemsLiveTest do
  @moduledoc """
  The open problems screen: what the shell's pulse gathered across every
  reachable namespace, worst first, each with why and the action that fixes
  it.
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
             "committed boundary on purpose"

    # The shell's pulse reads no runners, so the card claims nothing about them.
    refute has_element?(view, ~s([data-testid="problem-state-relay:default:relay_s-serving"]))
    refute has_element?(view, ~s([data-testid="problem-state-relay:default:relay_s-next"]))

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
end
