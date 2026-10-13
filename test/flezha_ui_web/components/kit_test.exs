defmodule FlezhaUiWeb.KitTest do
  @moduledoc """
  The console's component kit, element by element: what each renders, the
  accessible names and states it carries, and the markings its client
  behaviour and the browser tests read.
  """

  use FlezhaUiWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import FlezhaUiWeb.CoreComponents

  alias Phoenix.LiveView.JS

  defp parse(html), do: LazyHTML.from_fragment(html)
  defp q(html, selector), do: html |> parse() |> LazyHTML.query(selector)

  defp attr_of(html, selector, name),
    do: html |> q(selector) |> LazyHTML.attribute(name) |> List.first()

  test "the kit page is a dev route: without dev routes it answers 404", %{conn: conn} do
    conn = log_in_user(conn, FlezhaUi.AccountsFixtures.user_fixture())

    refute Application.get_env(:flezha_ui, :dev_routes)
    assert get(conn, "/dev/kit").status == 404
  end

  describe "the kit page" do
    # Mounted on its own: the route exists only with dev routes.
    setup %{conn: conn} do
      {:ok, view, html} = live_isolated(conn, FlezhaUiWeb.KitLive)
      %{view: view, html: html}
    end

    test "shows every group of the kit, with a theme switch", %{html: html} do
      for testid <-
            ~w(kit-theme kit-buttons kit-fields kit-combobox kit-choices kit-badges kit-grid) ++
              ~w(kit-figures kit-statements kit-overlays kit-flows) do
        assert html =~ ~s(data-testid="#{testid}"), "#{testid} is missing"
      end

      assert attr_of(html, ~s([data-testid="kit-theme"]), "data-flz-theme-toggle")
    end

    test "its switch, segmented control and combobox answer", %{view: view} do
      assert view |> element(~s([data-testid="kit-switch"])) |> render_click() =~
               ~s(aria-checked="false")

      html = render_click(view, "kit_segment", %{"value" => "three"})

      assert html |> q(~s([data-testid="kit-segmented"] [aria-pressed="true"])) |> LazyHTML.text() =~
               "Three"

      html = render_change(view, "kit_pick", %{"kit" => %{"pick" => "e"}})
      assert attr_of(html, "#kit-combobox-value", "value") == "e"
    end

    test "its drawer, dialog and toasts open and close", %{view: view} do
      assert view |> element(~s([data-testid="kit-open-drawer"])) |> render_click() =~
               ~s(id="kit-drawer")

      refute render_click(view, "kit_drawer", %{}) =~ ~s(id="kit-drawer")

      assert view |> element(~s([data-testid="kit-open-dialog"])) |> render_click() =~
               ~s(data-testid="kit-dialog")

      refute render_click(view, "kit_dialog", %{}) =~ ~s(data-testid="kit-dialog")

      assert view |> element(~s([data-testid="kit-toast-info"])) |> render_click() =~
               "An info toast."

      assert view |> element(~s([data-testid="kit-toast-error"])) |> render_click() =~
               "An error toast."
    end
  end

  describe "page_header/1" do
    test "carries the kind, the name, the sentence, the actions, the crumbs and the tabs" do
      assigns = %{
        crumbs: [%{label: "default", path: "/namespaces/default"}, %{label: "orders", path: nil}],
        tabs: [
          %{label: "Live", path: "/a", current?: true, testid: "tab-live"},
          %{label: "State", path: "/b"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <.page_header eyebrow="Relay" title="orders" crumbs={@crumbs} tabs={@tabs}>
          <:sentence>A flow relay.</:sentence>
          <:figures>Up for 2 hours.</:figures>
          <:actions><.button>Stop</.button></:actions>
        </.page_header>
        """)

      assert html |> q(~s([data-testid="page-eyebrow"])) |> LazyHTML.text() == "Relay"
      assert html |> q(~s(h1[data-testid="page-title"])) |> LazyHTML.text() =~ "orders"
      assert html |> q(~s([data-testid="page-figures"])) |> LazyHTML.text() =~ "Up for 2 hours."
      assert html |> q(~s([data-testid="page-sentence"])) |> LazyHTML.text() =~ "A flow relay."

      assert attr_of(html, ~s([data-testid="breadcrumb"] [aria-current="page"]), "aria-current") ==
               "page"

      assert attr_of(html, ~s([data-testid="tab-live"]), "aria-current") == "page"
      assert html |> q(".fui-page-actions .fui-btn") |> Enum.count() == 1
    end

    test "a headline sets its sentence in the display face" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.page_header eyebrow="Namespace" title="default" headline>
          <:sentence>Flowing.</:sentence>
        </.page_header>
        """)

      assert html =~ "fui-sentence--headline"
      refute html =~ ~s(data-testid="breadcrumb")
    end
  end

  describe "section/1" do
    test "a folded section states what it holds and reports its state" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.section fold="journal" open={false} digest="3 committed">
          <:title>Journal</:title>folded-away
        </.section>
        """)

      assert attr_of(html, ~s([data-testid="section-toggle-journal"]), "aria-expanded") == "false"
      assert html |> q(~s([data-testid="section-digest"])) |> LazyHTML.text() == "3 committed"
      refute html =~ "folded-away"
      assert attr_of(html, "section", "phx-hook") == "FlzSection"
    end

    test "an open section shows its body, and one with no fold has no hook" do
      assigns = %{}

      html = rendered_to_string(~H"<.section><:title>Plain</:title>body</.section>")

      assert html =~ "body"
      refute html =~ "phx-hook"
      assert html =~ ~s(class="fui-section)
    end
  end

  describe "button/1" do
    test "four variants at two sizes, and a link when it navigates" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button variant="danger" size="sm">Stop</.button>
        <.button variant="ghost" navigate="/cluster">Open</.button>
        """)

      assert attr_of(html, "button", "class") =~ "fui-btn--danger"
      assert attr_of(html, "button", "class") =~ "fui-btn--sm"
      assert attr_of(html, "a", "href") == "/cluster"
      assert attr_of(html, "a", "class") =~ "fui-btn--ghost"
    end
  end

  describe "state_badge/1" do
    test "health in words, in its tone, with a shape per verdict" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.state_badge value={:suspended} />
        <.state_badge value={:failed} count={2} />
        """)

      badges = q(html, ~s([data-testid="health-badge"]))
      assert LazyHTML.attribute(badges, "data-health") == ~w(suspended failed)
      assert html =~ "Suspended"
      assert html =~ "fui-badge--warning"
      assert html =~ "fui-badge--negative"
      assert html |> q(".fui-shape") |> LazyHTML.attribute("data-shape") == ~w(bars cross)
      assert html |> q(".fui-badge-count") |> LazyHTML.text() == "2"
    end

    test "health is never told by colour alone: every verdict has its own shape" do
      shapes =
        for health <- FlezhaUi.Service.NodeManager.health_verdicts(),
            do: FlezhaUiWeb.Words.say(:health, health).shape

      assert length(Enum.uniq(shapes)) == length(shapes)
    end

    test "any other kind is said in its words" do
      assigns = %{}

      html = rendered_to_string(~H|<.state_badge kind={:readiness} value={:ready} />|)

      assert html =~ "Ready"
      assert html =~ "fui-badge--positive"
      refute html =~ "data-health"
    end
  end

  describe "ident/1" do
    test "past sixteen characters it reads as its last seven, copyable whole" do
      assigns = %{}

      html = rendered_to_string(~H|<.ident value="default_58efe7505741" />|)

      assert html |> q("button.fui-ident") |> LazyHTML.text() |> String.trim() == "…7505741"
      assert attr_of(html, "button", "aria-label") == "default_58efe7505741"
      assert attr_of(html, "button", "data-fui-copy") == "default_58efe7505741"
    end

    test "a short id, or one kept whole, is plain text" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.ident value="orders" /><.ident value="a_very_long_relay_identifier" full />
        """)

      refute html =~ "<button"
      assert html =~ "a_very_long_relay_identifier"
    end
  end

  describe "sparkline/1" do
    test "draws the samples, oldest first, and nothing for fewer than two" do
      assigns = %{}

      html = rendered_to_string(~H|<.sparkline samples={[1, 4, 2]} />|)
      assert attr_of(html, "svg", "data-samples") == "3"
      assert attr_of(html, "svg", "aria-label") =~ "peak 4 msgs/s"

      assert rendered_to_string(~H|<.sparkline samples={[3]} />|) |> String.trim() == ""
    end

    test "reads maps at their key" do
      assert FlezhaUiWeb.CoreComponents.spark_points([0, 10], 10, 10) == "0.0,9.0 10.0,1.0"
    end
  end

  describe "controls" do
    test "a switch is a labelled button reporting its state" do
      assigns = %{}

      html = rendered_to_string(~H|<.switch checked={true} label="beam_vm" show_label={false} />|)

      assert attr_of(html, "button", "role") == "switch"
      assert attr_of(html, "button", "aria-checked") == "true"
      assert attr_of(html, "button", "aria-label") == "beam_vm"
    end

    test "a segmented control marks its choice" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.segmented label="Scope">
          <:option patch="/relays" current={true}>All</:option>
          <:option click="pick" value="one">One</:option>
        </.segmented>
        """)

      assert attr_of(html, "a", "aria-current") == "true"
      assert attr_of(html, "button", "aria-pressed") == "false"
      # Sent as the button's own value, which a browser click carries and
      # which would override a `phx-value-value`.
      assert attr_of(html, "button", "value") == "one"
    end

    test "a combobox keeps its value in a hidden input and filters a long list" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.combobox id="pick" name="f[x]" value="b" testid="pick">
          <:option :for={v <- ~w(a b c d e f g h i)} value={v}>{v}</:option>
        </.combobox>
        """)

      assert attr_of(html, ~s(input[type="hidden"]), "value") == "b"
      assert attr_of(html, ~s([data-testid="pick-b"]), "aria-checked") == "true"
      assert html =~ "data-fui-filter"
      assert attr_of(html, "[data-fui-pop-panel]", "hidden") == ""
    end

    test "a meter states its share, painted in its tone" do
      assigns = %{}

      html = rendered_to_string(~H|<.meter value={8} max={10} tone={:warning} label="8 of 10" />|)

      assert attr_of(html, ".fui-meter", "aria-valuenow") == "8"
      assert attr_of(html, ".fui-meter", "data-tone") == "warning"
      assert attr_of(html, ".fui-meter-fill", "style") =~ "80%"
    end
  end

  describe "grid/1 and row_menu/1" do
    test "rows carry their tone, activate on click and Enter, and keep actions in a menu" do
      assigns = %{rows: [%{id: "a", tone: "warning"}]}

      html =
        rendered_to_string(~H"""
        <.grid
          id="g"
          rows={@rows}
          row_tone={& &1.tone}
          row_activate={&JS.push("inspect", value: %{id: &1.id})}
          row_label={&"Inspect #{&1.id}"}
        >
          <:col :let={row} label="Id">{row.id}</:col>
          <:col :let={_row} label="Rate" num>1</:col>
          <:menu :let={row}>
            <.row_menu id={"m-#{row.id}"} label="Actions">
              <:item click="inspect" values={%{id: row.id}}>Inspect</:item>
              <:item click="stop" danger testid="stop-a">Stop</:item>
            </.row_menu>
          </:menu>
        </.grid>
        """)

      row = q(html, "tbody tr")
      assert LazyHTML.attribute(row, "data-tone") == ["warning"]
      assert LazyHTML.attribute(row, "tabindex") == ["0"]
      assert LazyHTML.attribute(row, "phx-key") == ["Enter"]
      assert LazyHTML.attribute(row, "aria-label") == ["Inspect a"]
      assert html |> q("td.fui-cell-num") |> Enum.count() == 1
      assert attr_of(html, ~s([data-testid="stop-a"]), "class") =~ "fui-menu-item--danger"
      assert attr_of(html, "[data-fui-pop-trigger]", "aria-label") == "Actions"
    end

    test "every cell names its column, and the table keeps its roles when laid out as cards" do
      assigns = %{rows: [%{id: "a"}]}

      html =
        rendered_to_string(~H"""
        <.grid id="g" rows={@rows}>
          <:col :let={row} label="Relay">{row.id}</:col>
          <:col :let={_row} label="Rate" num>1</:col>
          <:menu :let={row}>
            <.row_menu id={"m-#{row.id}"}>
              <:item click="stop">Stop</:item>
            </.row_menu>
          </:menu>
        </.grid>
        """)

      assert html |> q("td[data-label]") |> LazyHTML.attribute("data-label") == ["Relay", "Rate"]
      assert attr_of(html, "table", "role") == "table"
      assert html |> q("thead, tbody") |> LazyHTML.attribute("role") == ["rowgroup", "rowgroup"]
      assert html |> q("tr") |> LazyHTML.attribute("role") == ["row", "row"]
      assert html |> q("th") |> LazyHTML.attribute("role") |> Enum.uniq() == ["columnheader"]
      assert html |> q("td") |> LazyHTML.attribute("role") == ["cell", "cell", "cell"]
    end
  end

  describe "overlays" do
    test "a drawer is a named modal dialog that closes on Escape and returns focus" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.drawer id="inspector" eyebrow="Relay" title="orders" on_close="inspect_close">body</.drawer>
        """)

      assert attr_of(html, "#inspector", "role") == "dialog"
      assert attr_of(html, "#inspector", "aria-labelledby") == "inspector-title"
      assert attr_of(html, "#inspector", "phx-window-keydown") == "inspect_close"
      assert attr_of(html, "#inspector", "phx-key") == "Escape"
      assert attr_of(html, "#inspector", "phx-hook") == "FlzFocus"
    end

    test "a confirmation's destructive action is the solid danger button" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog title="Stop?" confirm_label="Stop" on_confirm="stop" on_cancel="cancel">
          Sure?
        </.confirm_dialog>
        """)

      assert html =~ "fui-btn--danger"
      assert attr_of(html, ".fui-dialog", "phx-window-keydown") == "cancel"
    end

    test "a popover's panel starts hidden and keeps its open state across patches" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.popover id="p" label="More"><:trigger>…</:trigger>item</.popover>
        """)

      assert attr_of(html, "[data-fui-pop-panel]", "hidden") == ""
      assert attr_of(html, "[data-fui-pop-panel]", "phx-mounted") =~ "ignore_attrs"
      assert attr_of(html, "[data-fui-pop-trigger]", "aria-expanded") == "false"
    end

    test "an info toast is timed, an error toast is an alert" do
      assigns = %{flash: %{"info" => "Saved.", "error" => "Refused."}}

      html = rendered_to_string(~H|<.flash_group flash={@flash} />|)

      assert attr_of(html, ~s([data-testid="toast-info"]), "role") == "status"
      assert attr_of(html, ~s([data-testid="toast-info"]), "phx-hook") == "FlzToast"
      assert attr_of(html, ~s([data-testid="toast-error"]), "role") == "alert"
    end
  end

  describe "live activity" do
    test "a changing figure is marked by the client, whose mark the patch leaves alone" do
      assigns = %{}

      html = rendered_to_string(~H|<.live_value id="parked" value={3} />|)

      assert attr_of(html, "#parked", "phx-hook") == "FlzChange"
      assert attr_of(html, "#parked", "data-value") == "3"
      assert attr_of(html, "#parked", "phx-mounted") =~ "data-changed"
    end
  end

  describe "statements" do
    test "an empty state teaches and offers its action" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state icon="hero-clock">
          A schedule starts a relay.<:action><.button>New</.button></:action>
        </.empty_state>
        """)

      assert html =~ "A schedule starts a relay."
      assert html |> q(".fui-empty-actions .fui-btn") |> Enum.count() == 1
    end

    test "a skeleton is busy, never an empty table" do
      assigns = %{}

      html = rendered_to_string(~H|<.skeleton rows={3} />|)

      assert attr_of(html, "div", "aria-busy") == "true"
      assert html |> q(".fui-skeleton") |> Enum.count() == 3
      refute html =~ "<table"
    end

    test "a term shows its definition as its description and opens help" do
      assigns = %{}

      html = rendered_to_string(~H|<.term key="runner" />|)

      assert attr_of(html, "button", "aria-describedby") == "term-runner"
      assert html |> q("#term-runner") |> LazyHTML.text() =~ "SDK-side process"
      assert attr_of(html, "button", "data-fui-help-open") == ""
    end

    test "steps mark the current step and the ones done" do
      assigns = %{}

      html = rendered_to_string(~H|<.steps steps={~w(Factory Details Review)} current={1} />|)

      assert html |> q("[data-done]") |> LazyHTML.text() =~ "Factory"
      assert html |> q(~s([aria-current="step"])) |> LazyHTML.text() =~ "Details"
    end

    test "a code block wraps rather than scrolling sideways" do
      css = File.read!("assets/css/console/components.css")
      [rule] = Regex.run(~r/\.fui-code \{[^}]*\}/, css)

      assert rule =~ "white-space: pre-wrap"
      assert rule =~ "overflow-wrap: anywhere"
    end

    test "a strip sizes each verdict by its count, in its tone" do
      assigns = %{}

      html =
        rendered_to_string(~H|<.strip counts={[{:healthy, 6}, {:failed, 1}, {:degraded, 0}]} />|)

      assert html |> q(".fui-strip-part") |> LazyHTML.attribute("data-tone") ==
               ~w(positive negative)
    end
  end
end
