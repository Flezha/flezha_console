defmodule FlezhaUiWeb.ErrorHTMLTest do
  use FlezhaUiWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template

  test "an unknown route answers the not-found page on the auth layout", %{conn: conn} do
    html = conn |> get("/no-such-page") |> html_response(404)

    assert html =~ ~s(data-testid="not-found")
    assert html =~ ~s(class="fui-brand fui-brand--canvas")
    assert html =~ "Flezha UI"
    assert html =~ ~s(src="/images/badger-not-found.webp")
    assert html =~ ~s(alt="")
    assert html =~ ~s(href="/")
    assert html =~ "/assets/app.css"
  end

  test "renders 500.html" do
    assert render_to_string(FlezhaUiWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end
end
