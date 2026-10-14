defmodule FlezhaUiWeb.ErrorHTMLTest do
  use FlezhaUiWeb.ConnCase, async: true

  test "an unknown route answers the not-found page on the auth layout", %{conn: conn} do
    html = conn |> get("/default/relays/testnet_chain") |> html_response(404)

    assert html =~ ~s(data-testid="not-found")
    assert html =~ "/images/badger-not-found.png"
    assert html =~ ~s(class="fui-brand fui-brand--canvas")
    assert html =~ ~s(href="/")
    assert html =~ "/assets/app.css"
  end
end
