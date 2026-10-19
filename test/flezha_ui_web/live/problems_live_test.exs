defmodule FlezhaUiWeb.ProblemsLiveTest do
  @moduledoc """
  The open problems screen: what the shell's pulse gathered across every
  reachable namespace, worst first, each with its condition rows and the
  action that fixes it.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Relay

  defp fleet(node, rows),
    do: FakeController.set_fleet(node, namespaces: ["default"], rows: %{"default" => rows})

  defp row(id, health), do: FakeController.relay_row(id, %{health: health})

  defp item_ids(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("li.fui-problem")
    |> LazyHTML.attribute("data-testid")
  end

  defp row_text(html, item, key), do: condition_value(html, "problem-state-#{item}", key)

  defp serve(node, runners),
    do: FakeController.set(node, {Flezha.Service.Fleet, :runners_for_factory}, {:ok, runners})

  test "says nothing before the pulse has run", %{conn: conn, node: node} do
    fleet(node, [row("relay_h", :halted)])

    {:ok, _view, html} = live(conn, ~p"/problems")

    assert html =~ ~s(data-testid="problems-loading")
    refute html =~ ~s(data-testid="problems-clear")
  end

  test "lists every problem worst first, each with its condition rows and its fix",
       %{conn: conn, node: node} do
    fleet(node, [row("relay_h", :halted), row("relay_d", :degraded), row("relay_s", :suspended)])

    {view, html} = live_loaded(conn, ~p"/problems")

    # The suspended relay waits only on a runner, so its factory carries it.
    assert item_ids(html) == [
             "problem-factory:default:store_input",
             "problem-relay:default:relay_h",
             "problem-relay:default:relay_d"
           ]

    factory = "factory:default:store_input"
    assert row_text(html, factory, "state") == "No runner"
    assert row_text(html, factory, "impact") == "1 relay waits: 1 suspended"
    assert row_text(html, factory, "handled") == "You"
    assert row_text(html, factory, "next") == "Start a runner that serves store_input"

    assert row_text(html, "relay:default:relay_d", "handled") == "Flezha"
    assert row_text(html, "relay:default:relay_d", "next") == "Repaired in place by Flezha"
    assert row_text(html, "relay:default:relay_h", "handled") == "You"

    # Every card has the same rows in the same order.
    for item <- [factory, "relay:default:relay_h", "relay:default:relay_d"] do
      labels =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s([data-testid="problem-state-#{item}"] dt))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert Enum.take(labels -- ["Runner"], 5) ==
               ["State", "Cause", "Impact", "Handled by", "Next step"]
    end

    refute html =~ "Who can run it"

    assert has_element?(
             view,
             ~s(a[data-testid="problem-open-relay:default:relay_d"][href="/namespaces/default/relays/relay_d"])
           )

    assert has_element?(view, ~s(a[data-testid="problem-open-#{factory}"][href="/cluster"]))
  end

  test "a suspended relay a runner can wake is no problem", %{conn: conn, node: node} do
    fleet(node, [row("relay_s", :suspended)])
    serve(node, [%{id: "runner-a"}])

    {_view, html} = live_loaded(conn, ~p"/problems")

    assert html =~ ~s(data-testid="problems-clear")
  end

  test "the pulse reads runners once per waiting factory, and never for healthy relays",
       %{conn: conn, node: node} do
    reads = fn ->
      length(FakeController.calls(node, {Flezha.Service.Fleet, :runners_for_factory}))
    end

    fleet(node, [row("a", :healthy), row("b", :healthy)])
    {_view, _html} = live_loaded(conn, ~p"/problems")
    assert reads.() == 0

    fleet(node, Enum.map(1..4, &row("s#{&1}", :suspended)) ++ [row("d", :degraded)])
    {view, _html} = live_loaded(conn, ~p"/problems")
    before = reads.()
    send(view.pid, :shell_pulse)
    render_async(view)

    # Four suspended relays of one factory, one read a pulse.
    assert reads.() - before == 1
  end

  test "diagnosis answers beneath its problem", %{conn: conn, node: node} do
    fleet(node, [row("relay_d", :degraded)])

    {view, _html} = live_loaded(conn, ~p"/problems")

    assert view
           |> element(~s([data-testid="problem-diagnose-relay:default:relay_d"]))
           |> render_click() =~ ~s(data-testid="problem-diagnosis-relay:default:relay_d")

    assert [["default", "relay_d", _ctx]] = FakeController.calls(node, {Relay, :diagnose})
  end

  test "a problem that resolves leaves on the next pulse", %{conn: conn, node: node} do
    fleet(node, [row("relay_d", :degraded)])

    {:ok, view, _html} = live(conn, ~p"/problems")
    assert render_async(view) =~ ~s(data-testid="problem-relay:default:relay_d")

    fleet(node, [row("relay_d", :healthy)])
    send(view.pid, :shell_pulse)

    html = render_async(view)
    refute html =~ ~s(data-testid="problem-relay:default:relay_d")
    assert html =~ ~s(data-testid="problems-clear")
    assert html =~ "All clear"
  end

  test "a runner connecting clears its factory's item", %{conn: conn, node: node} do
    fleet(node, [row("relay_s", :suspended)])

    {:ok, view, _html} = live(conn, ~p"/problems")
    assert render_async(view) =~ ~s(data-testid="problem-factory:default:store_input")

    serve(node, [%{id: "runner-a"}])
    send(view.pid, :shell_pulse)

    html = render_async(view)
    refute html =~ ~s(data-testid="problem-factory:default:store_input")
    refute html =~ ~s(data-testid="problem-relay:default:relay_s")
    assert html =~ ~s(data-testid="problems-clear")
  end
end
