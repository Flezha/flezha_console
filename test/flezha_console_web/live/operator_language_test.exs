defmodule FlezhaConsoleWeb.OperatorLanguageTest do
  @moduledoc """
  The raw-atom gate: no routed screen shows the controller's atoms to an
  operator. Every value is said in words through `FlezhaConsoleWeb.Words`; a
  `:local_only` or `:ready` in what the screen reads is a value that skipped
  it.

  Code, preformatted payloads and key caps are exempt: what sits in them is
  shown as the controller wrote it on purpose.
  """

  use FlezhaConsoleWeb.LiveCase

  @routes [
    "/namespaces",
    "/namespaces/default",
    "/namespaces/default/relays",
    "/relays",
    "/namespaces/default/plugins",
    "/plugins",
    "/namespaces/default/schedules",
    "/schedules",
    "/problems",
    "/cluster",
    "/controller",
    "/observability",
    "/dlq",
    "/audit",
    "/namespaces/default/relays/relay_a",
    "/namespaces/default/relays/relay_a/listen",
    "/namespaces/default/relays/relay_a/state"
  ]

  # A colon opening a lowercase word, not preceded by a word character or
  # another colon: `:ready`, but not `12:30`, `http://` or `Health: ok`.
  @atom ~r/(?<![\w:]):[a-z_][a-z0-9_]*[?!]?(?![\w:\/])/

  setup %{node: node} do
    FakeController.set_fleet(node,
      namespaces: ["default"],
      rows: %{
        "default" => [
          FakeController.relay_row("relay_a"),
          FakeController.relay_row("relay_s", %{health: :suspended, node: nil})
        ]
      }
    )

    :ok
  end

  defp said(html) do
    doc = LazyHTML.from_document(html)
    exempt = doc |> LazyHTML.query("code, pre, kbd, script, style") |> Enum.map(&LazyHTML.text/1)
    Enum.reduce(exempt, LazyHTML.text(doc), &String.replace(&2, &1, "", global: false))
  end

  test "no routed screen shows a raw atom", %{conn: conn} do
    for route <- @routes do
      {:ok, view, _html} = live(conn, route)
      hits = Regex.scan(@atom, said(render(view))) |> List.flatten() |> Enum.uniq()

      assert hits == [], "#{route} shows #{Enum.join(hits, ", ")}"
    end
  end

  test "the settings page shows no raw atom", %{conn: conn} do
    html = conn |> get(~p"/users/settings") |> html_response(200)

    assert Regex.scan(@atom, said(html)) == []
  end
end
