defmodule FlezhaConsoleWeb.LauncherTest do
  @moduledoc """
  The guided relay start (`FlezhaConsoleWeb.Live.Launcher`), which a namespace's
  home and the relays index both host.

  Its behaviour is asserted once, on the namespace home. Each host is a row
  proving the launcher is wired there: its control opens it, a start lands in
  the right namespace and shows up on the host, and the host holds still while
  the form is open. The index, which asks for the namespace, has its own
  describe for the choice the home never offers.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.Relay

  @home "/namespaces/default"

  setup %{node: node} do
    with_relays(node, [])

    FakeController.set(
      node,
      {Fleet, :factories},
      FakeController.rows([
        %{id: "store_input", description: "stores its input", run: :flow, runners: ["runner-a"]},
        %{id: "chat_loop_steps", description: nil, run: :steps, runners: ["runner-a"]}
      ])
    )

    :ok
  end

  defp with_relays(node, ids) do
    FakeController.set_fleet(node,
      namespaces: ["default", "staging"],
      rows: %{"default" => Enum.map(ids, &FakeController.relay_row/1)}
    )
  end

  # Whether the host shows the one relay `id` the controller now holds: Home
  # counts it, the index lists it. Home reads in the background, so the reads
  # in flight answer first.
  defp shows?(view, host, id) do
    render_async(view)
    listed?(view, host, id)
  end

  defp listed?(view, %{lists: :count}, _id),
    do: has_element?(view, ~s([data-testid="ns-relays-value"]), "1")

  defp listed?(view, %{lists: prefix}, id),
    do: has_element?(view, ~s([data-testid="#{prefix}-#{id}"]))

  defp click(view, testid), do: view |> element(~s([data-testid="#{testid}"])) |> render_click()

  defp open(conn, route \\ @home) do
    {:ok, view, _html} = live(conn, route)
    render_async(view)
    click(view, "start-relay-btn")
    view
  end

  defp details(view, fields) do
    view
    |> form(~s(form[phx-submit="launcher_next"]), start: fields)
    |> render_submit()
  end

  # Factory, Continue, then Details: answers the review.
  defp review(view, fields \\ %{id: "relay_new"}) do
    click(view, "factory-choice-store_input")
    click(view, "start-next-btn")
    details(view, fields)
  end

  defp typed_factory(view, factory),
    do: view |> form(~s(form[phx-submit="launcher_pick"]), factory: factory) |> render_submit()

  defp starts(node), do: FakeController.calls(node, {Relay, :start})

  describe "on each screen that hosts it" do
    @hosts [
      %{screen: "namespace home", route: @home, asks_namespace: false, lists: :count},
      %{screen: "relays index", route: "/relays", asks_namespace: true, lists: "relay-index-row"}
    ]

    for host <- @hosts do
      @host host

      test "#{host.screen}: the start control walks factory, details and review into default",
           %{conn: conn, node: node} do
        view = open(conn, @host.route)
        assert has_element?(view, ~s([data-testid="input-namespace"])) == @host.asks_namespace

        html = review(view, %{id: "relay_new", init_values: ~s({"seed": 7})})
        assert text_of(html, ~s([data-testid="review-namespace"])) == "default"
        assert text_of(html, ~s([data-testid="review-init-values"])) =~ ~r/seed\s*:?\s*7/
        assert starts(node) == []

        with_relays(node, ["relay_new"])
        click(view, "start-submit-btn")

        assert [["default", fields, %{source: :ui}]] = starts(node)
        assert fields[:id] == "relay_new"
        assert fields[:factory_id] == "store_input"
        assert fields[:init_values] == %{"seed" => 7}
        refute Keyword.has_key?(fields, :run)
        refute Keyword.has_key?(fields, :kind)

        assert view |> element(~s([data-testid="start-result-link"])) |> render() =~
                 ~s(href="/namespaces/default/relays/relay_new")

        # The host reloads after the start, so it shows what the controller now holds.
        assert shows?(view, @host, "relay_new")
      end

      test "#{host.screen}: holds still while the form is open, and a tick looks up no factory",
           %{conn: conn, node: node} do
        {:ok, view, _html} = live(conn, @host.route)
        render_async(view)
        send(view.pid, :refresh)
        _rendered = render_async(view)
        assert FakeController.calls(node, {Fleet, :runners_for_factory}) == []

        click(view, "start-relay-btn")
        with_relays(node, ["relay_late"])
        send(view.pid, :refresh)
        refute shows?(view, @host, "relay_late")

        click(view, "start-cancel-btn")
        send(view.pid, :refresh)
        assert shows?(view, @host, "relay_late")
      end
    end
  end

  describe "the guided start" do
    test "each factory states its run and its runners, and an unserved one cannot be chosen",
         %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :factories},
        FakeController.rows([
          %{
            id: "store_input",
            description: "stores its input",
            run: :flow,
            runners: ["runner-a"]
          },
          %{id: "chat_loop_steps", description: nil, run: :steps, runners: []}
        ])
      )

      html = conn |> open() |> render()

      served = text_of(html, ~s([data-testid="factory-choice-store_input"]))
      assert served =~ "stores its input"
      assert served =~ "flow"
      assert served =~ "Served by 1 runner."

      unserved = text_of(html, ~s([data-testid="factory-choice-chat_loop_steps"]))
      assert unserved =~ "steps"
      assert unserved =~ "Unavailable: no runner serves it right now."
      assert html =~ ~r/<button[^>]*disabled[^>]*data-testid="factory-choice-chat_loop_steps"/
    end

    test "the chosen factory's run is stated, and how a relay runs is never asked", %{
      conn: conn
    } do
      view = open(conn)

      click(view, "factory-choice-chat_loop_steps")
      html = click(view, "start-next-btn")

      assert html =~ "which runs as steps"
      refute has_element?(view, ~s([name="start[run]"]))
      refute has_element?(view, ~s([name="start[kind]"]))
    end

    test "choosing a factory describes it beside the list, and Continue moves on", %{conn: conn} do
      view = open(conn)
      assert has_element?(view, ~s{[data-testid="start-next-btn"][disabled]})

      html = click(view, "factory-choice-store_input")

      detail = text_of(html, ~s([data-testid="factory-detail"]))
      assert detail =~ "stores its input"
      assert detail =~ "Each record passes through its tasklets once"

      assert has_element?(
               view,
               ~s([data-testid="factory-choice-store_input"][aria-pressed="true"])
             )

      assert text_of(html, ~s([data-testid="start-steps-step-0"])) =~ "store_input · flow"
      refute html =~ ~s(id="start-details")

      html = click(view, "start-next-btn")
      assert html =~ ~s(id="start-details")
    end

    test "the init values are checked as they are typed", %{conn: conn} do
      view = open(conn)
      click(view, "factory-choice-store_input")
      click(view, "start-next-btn")

      change = fn values ->
        view
        |> form(~s(form[phx-submit="launcher_next"]), start: %{init_values: values})
        |> render_change()
        |> text_of(~s([data-testid="init-values-check"]))
      end

      assert change.("") =~ "None: each tasklet starts with the state its class builds."
      assert change.(~s({"ohlc": {}, "agg": 1})) =~ ~r/Seeds 2 tasklets:\s*agg, ohlc/
      assert change.("{") =~ "Init Values must be valid JSON."
    end

    test "the review states the command that does the same, and a done step goes back", %{
      conn: conn
    } do
      view = open(conn)
      html = review(view, %{id: "my relay", init_values: ~s({"seed": 7})})

      assert text_of(html, ~s([data-testid="start-command"])) ==
               ~s(flz relay start store_input --namespace default --id 'my relay' --init-values '{"seed":7}')

      assert text_of(html, ~s([data-testid="start-steps-step-1"])) =~
               "my relay · 1 tasklet seeded"

      html = click(view, "start-steps-go-0")
      assert html =~ ~s(data-testid="factory-detail")
      refute has_element?(view, ~s([data-testid="start-steps-go-1"]))
    end

    test "Back returns from the review to the details, and a forged second Start starts nothing more",
         %{conn: conn, node: node} do
      view = open(conn)
      review(view)

      html = click(view, "start-back-btn")
      assert html =~ ~s(data-testid="start-next-btn")
      refute html =~ ~s(data-testid="start-review")

      details(view, %{id: "relay_new"})
      click(view, "start-submit-btn")
      render_click(view, "launcher_submit", %{})

      assert [["default", _fields, _ctx]] = starts(node)
    end

    test "an empty id is left for the controller to generate, and the drawn id is linked", %{
      conn: conn,
      node: node
    } do
      view = open(conn)
      html = review(view, %{id: ""})
      assert text_of(html, ~s([data-testid="review-id"])) =~ "Generated by the controller"

      click(view, "start-submit-btn")

      assert [["default", fields, _ctx]] = starts(node)
      refute Keyword.has_key?(fields, :id)

      assert view |> element(~s([data-testid="start-result-link"])) |> render() =~
               ~s(href="/namespaces/default/relays/relay-generated")
    end

    test "an id already running is said so, not reported as started", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :start},
        {:ok, %{id: "relay_new", outcome: :already_running}}
      )

      view = open(conn)
      review(view)
      html = click(view, "start-submit-btn")

      assert text_of(html, ~s([data-testid="start-result"])) =~ "already running in default"
      refute html =~ "Relay started"
    end

    test "a refused start states the controller's error on the form", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :start},
        FakeController.error("authz.role_insufficient", "viewers cannot start relays")
      )

      view = open(conn)
      review(view)
      html = click(view, "start-submit-btn")

      error = text_of(html, ~s([data-testid="start-error"]))
      assert error =~ "authz.role_insufficient"
      assert error =~ "viewers cannot start relays"
      refute html =~ ~s(data-testid="start-result")
    end

    test "init values that are not JSON are refused before the controller", %{
      conn: conn,
      node: node
    } do
      view = open(conn)

      html = review(view, %{id: "relay_new", init_values: "not json{{{"})

      assert text_of(html, ~s([data-testid="start-error"])) =~ "Init Values must be valid JSON."
      refute html =~ ~s(data-testid="start-review")
      assert starts(node) == []
    end

    test "a namespace with no factories says so, and a forged start is refused", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Fleet, :factories}, FakeController.rows([]))

      view = open(conn)
      html = render(view)

      assert text_of(html, ~s([data-testid="start-no-factories"])) =~
               "No factories are registered"

      refute html =~ ~s(data-testid="factory-choices")

      html =
        render_submit(view, "launcher_submit", %{
          "start" => %{"id" => "relay_new", "factory_id" => "store_input", "init_values" => ""}
        })

      assert text_of(html, ~s([data-testid="start-error"])) =~ "No factories are registered"
      assert starts(node) == []
    end

    test "a refused catalog says so and takes a typed factory id, which is required", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Fleet, :factories}, FakeController.error("authz.no_role_binding"))

      view = open(conn)
      assert render(view) =~ "authz.no_role_binding"

      typed_factory(view, "")
      html = details(view, %{id: "relay_new"})
      assert text_of(html, ~s([data-testid="start-error"])) =~ "A Factory ID is required."
      assert starts(node) == []

      click(view, "start-back-btn")
      typed_factory(view, "store_input")
      details(view, %{id: "relay_new"})
      click(view, "start-submit-btn")

      assert [["default", fields, _ctx]] = starts(node)
      assert fields[:factory_id] == "store_input"
    end
  end

  describe "a screen that asks for the namespace" do
    test "offers each reachable namespace and opens on the one in scope", %{conn: conn} do
      view = open(conn, "/namespaces/staging/relays")

      assert has_element?(view, ~s([data-testid="input-namespace-default"]))
      assert has_element?(view, ~s([data-testid="input-namespace-staging"][aria-checked="true"]))
      assert has_element?(view, ~s(#input-namespace-value[value="staging"]))
    end

    test "choosing another namespace re-reads its factories, and the start goes there", %{
      conn: conn,
      node: node
    } do
      view = open(conn, "/relays")

      # The namespace's option sets the form's hidden value in the browser.
      view
      |> form(~s(form[phx-change="launcher_change"]))
      |> render_change(%{start: %{namespace: "staging"}})

      assert [["default", _], ["staging", _]] = FakeController.calls(node, {Fleet, :factories})

      review(view)
      html = click(view, "start-submit-btn")

      assert [["staging", _fields, _ctx]] = starts(node)
      assert text_of(html, ~s([data-testid="start-result"])) =~ "It runs in staging as"
    end
  end
end
