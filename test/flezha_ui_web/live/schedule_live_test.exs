defmodule FlezhaUiWeb.ScheduleLiveTest do
  @moduledoc """
  The schedules screen, against a controller whose hub can be made to disagree
  with its store.

  The browser suite covers creating and removing against a healthy controller.
  The state it cannot produce is the one this screen exists to distinguish: an
  entry the store holds but no node fires.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.Relay
  alias Flezha.Service.Schedule

  # A stored entry as `Schedule.list/1` answers it, joined by the controller
  # with what the schedule hub holds for it.
  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        name: "nightly",
        cron: "0 3 * * *",
        timezone: "Etc/UTC",
        namespace: "default",
        factory_id: "echo_steps",
        init_values: %{},
        node: :"flezha@hub-1",
        last_fire: nil,
        next_fire: ~U[2031-06-01 03:00:00Z]
      },
      overrides
    )
  end

  defp with_entries(node, entries),
    do: FakeController.set(node, {Schedule, :list}, {:ok, entries})

  defp valid_form(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "nightly",
        "cron" => "0 3 * * *",
        "timezone" => "Etc/UTC",
        "namespace" => "default",
        "factory_id" => "echo_steps",
        "init_values" => ""
      },
      overrides
    )
  end

  defp open_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/schedules")
    render_click(view, "open_form", %{})
    view
  end

  defp adds(node), do: FakeController.calls(node, {Schedule, :add})

  describe "listing" do
    test "renders the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/schedules")

      assert html =~ ~s(data-testid="schedule-empty")
      assert html =~ ~s(data-testid="schedule-new-empty-btn")
      assert html =~ ~s(data-testid="scope-switch")
    end

    test "an entry a node fires reads as active, with its next fire", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      {:ok, view, html} = live(conn, ~p"/schedules")

      assert html =~ ~s(data-testid="schedule-row-nightly")
      assert html =~ ~s(data-testid="schedule-menu-nightly")
      status = view |> element(~s([data-testid="schedule-status-nightly"])) |> render()
      assert status =~ ~r/>\s*Active\s*</
      assert status =~ "A node holds this schedule"
      assert html =~ "echo_steps"

      assert view |> element(~s([data-testid="schedule-next-fire-nightly"])) |> render() =~
               "2031-06-01"
    end

    test "an entry that has fired shows when", %{conn: conn, node: node} do
      last_fire = %{at: ~U[2031-05-31 03:00:00.057538Z], outcome: :ok, instance_id: "nightly@1"}
      with_entries(node, [entry(%{last_fire: last_fire})])

      {:ok, _view, html} = live(conn, ~p"/schedules")

      assert html =~ "2031-05-31 03:00:00"
    end

    test "an entry no node fires is distinguished, not left blank", %{conn: conn, node: node} do
      with_entries(node, [entry(%{node: nil, next_fire: :none})])

      {:ok, view, _html} = live(conn, ~p"/schedules")

      status = view |> element(~s([data-testid="schedule-status-nightly"])) |> render()
      assert status =~ ~r/>\s*Inactive\s*</
      assert status =~ "No node holds this schedule right now"
    end

    test "the scoped screen lists the namespace's entries and says how it scopes", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [entry(), entry(%{name: "elsewhere", namespace: "staging"})])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default/schedules")

      assert html =~ ~s(data-testid="schedule-row-nightly")
      refute html =~ ~s(data-testid="schedule-row-elsewhere")
      assert html =~ ~s(data-testid="schedule-scope-notice")
    end

    test "renders the controller's refusal instead of crashing", %{conn: conn, node: node} do
      FakeController.set(node, {Schedule, :list}, FakeController.error("authz.role_insufficient"))

      {:ok, _view, html} = live(conn, ~p"/schedules")

      assert html =~ ~s(data-testid="runtime-error")
      assert html =~ "authz.role_insufficient"
    end
  end

  describe "creating" do
    test "stores and arms it in one call, and reports it", %{conn: conn, node: node} do
      view = open_form(conn)
      assert has_element?(view, ~s([data-testid="schedule-steps"]))

      html = render_submit(view, "create", %{"schedule" => valid_form()})

      assert html =~ "Schedule nightly created."
      assert [[fields, %{source: :ui}]] = adds(node)
      assert fields[:name] == "nightly"
      assert fields[:factory_id] == "echo_steps"
      assert fields[:namespace] == "default"
    end

    test "requires the fields the controller requires", %{conn: conn, node: node} do
      view = open_form(conn)

      html = render_submit(view, "create", %{"schedule" => valid_form(%{"name" => ""})})

      assert html =~ ~s(data-testid="schedule-form-error")
      assert html =~ "Required: Name."
      assert adds(node) == []
    end

    test "rejects init values that are not JSON before calling the controller", %{
      conn: conn,
      node: node
    } do
      view = open_form(conn)

      html =
        render_submit(view, "create", %{"schedule" => valid_form(%{"init_values" => "{nope"})})

      assert html =~ "Init Values must be valid JSON."
      assert adds(node) == []
    end

    test "an unknown timezone is refused with the controller's message", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Schedule, :add},
        FakeController.error(
          "schedule.invalid_timezone",
          "'Mars/Olympus_Mons' is not an IANA time zone"
        )
      )

      view = open_form(conn)

      html =
        render_submit(view, "create", %{
          "schedule" => valid_form(%{"timezone" => "Mars/Olympus_Mons"})
        })

      assert html =~ "is not an IANA time zone"
      assert html =~ ~s(data-testid="schedule-form-modal")
    end

    test "a flow factory is refused with the controller's message", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Schedule, :add},
        FakeController.error(
          "relay.factory_not_steps",
          "factory 'store_input' is a flow relay, and only a steps one can be spawned"
        )
      )

      view = open_form(conn)

      html =
        render_submit(view, "create", %{
          "schedule" => valid_form(%{"factory_id" => "store_input"})
        })

      assert html =~ "only a steps one can be spawned"
    end

    test "a taken name is reported", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Schedule, :add},
        FakeController.error(
          "schedule.already_exists",
          "a schedule named 'nightly' already exists"
        )
      )

      view = open_form(conn)

      assert render_submit(view, "create", %{"schedule" => valid_form()}) =~
               "a schedule named &#39;nightly&#39; already exists"
    end
  end

  describe "choosing a target" do
    setup %{node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        {:ok, [%{namespace: "default", running: true}, %{namespace: "staging", running: true}]}
      )

      FakeController.set(
        node,
        {Fleet, :factories},
        {:per_arg, 0,
         %{
           "default" =>
             {:ok,
              [
                %{id: "default_steps", description: "spawns things", run: :steps},
                %{id: "default_flow", description: "forwards things", run: :flow}
              ]},
           "staging" => {:ok, [%{id: "staging_steps", description: "spawns things", run: :steps}]}
         }, {:ok, []}}
      )

      FakeController.set(node, {Fleet, :runners_for_factory}, {:ok, ["runner-a"]})

      :ok
    end

    test "the namespace field offers the namespaces the token can reach", %{conn: conn} do
      view = open_form(conn)

      selector = ~s([data-testid="schedule-input-namespace"] option)
      assert has_element?(view, selector <> ~s([value="default"]))
      assert has_element?(view, selector <> ~s([value="staging"]))
    end

    test "the factory field offers only the chosen namespace's steps factories", %{conn: conn} do
      html = conn |> open_form() |> render()

      assert html =~ "default_steps — spawns things"
      refute html =~ "default_flow"
    end

    test "a factory no runner serves is marked as such", %{conn: conn, node: node} do
      FakeController.set(node, {Fleet, :runners_for_factory}, {:ok, []})

      assert conn |> open_form() |> render() =~ "(no runner)"
    end

    test "changing the namespace offers the new namespace's factories", %{conn: conn} do
      view = open_form(conn)

      html =
        render_change(view, "form_change", %{
          "schedule" => valid_form(%{"namespace" => "staging"})
        })

      assert html =~ "staging_steps"
      refute html =~ "default_steps"
    end

    test "a factory the new namespace does not register stops being chosen", %{conn: conn} do
      view = open_form(conn)

      render_change(view, "form_change", %{
        "schedule" => valid_form(%{"namespace" => "staging", "factory_id" => "default_steps"})
      })

      refute has_element?(view, ~s([data-testid="schedule-input-factory"] option[selected]))
    end

    test "a refused listing leaves both fields typeable and the form submittable", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.error("controller.timeout")
      )

      FakeController.set(node, {Fleet, :factories}, FakeController.error("controller.timeout"))

      view = open_form(conn)

      assert render(view) =~ "The choices could not be read"

      render_submit(view, "create", %{"schedule" => valid_form()})

      assert [[fields, _ctx]] = adds(node)
      assert fields[:namespace] == "default"
      assert fields[:factory_id] == "echo_steps"
    end

    test "opening the form is what reads the catalog, not the tick", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/schedules")
      send(view.pid, :refresh)
      _rendered = render(view)

      assert FakeController.calls(node, {Fleet, :factories}) == []

      render_click(view, "open_form", %{})

      assert [["default", %{source: :ui}]] = FakeController.calls(node, {Fleet, :factories})
    end

    test "a scoped screen's form opens aimed at its namespace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/staging/schedules")
      html = render_click(view, "open_form", %{})

      assert html =~ "staging_steps"
    end
  end

  describe "removing" do
    setup %{node: node} do
      with_entries(node, [entry()])
      :ok
    end

    test "is confirm-gated, and cancelling leaves the schedule alone", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/schedules")

      html = render_click(view, "confirm_remove", %{"name" => "nightly"})
      assert html =~ ~s(data-testid="schedule-remove-modal")

      html = render_click(view, "cancel_remove", %{})
      refute html =~ ~s(data-testid="schedule-remove-modal")
      assert html =~ ~s(data-testid="schedule-row-nightly")

      assert FakeController.calls(node, {Schedule, :remove}) == []
    end

    test "removes and retracts in one call", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/schedules")

      render_click(view, "confirm_remove", %{"name" => "nightly"})
      assert render_click(view, "remove", %{"name" => "nightly"}) =~ "Schedule nightly removed."

      assert [["nightly", %{source: :ui}]] = FakeController.calls(node, {Schedule, :remove})
    end

    test "reports a refused removal", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Schedule, :remove},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/schedules")
      render_click(view, "confirm_remove", %{"name" => "nightly"})

      assert render_click(view, "remove", %{"name" => "nightly"}) =~ "authz.role_insufficient"
    end
  end

  describe "running a schedule now" do
    test "asks first, and a cancelled run starts nothing", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      {:ok, view, _html} = live(conn, ~p"/schedules")

      assert view |> element(~s([data-testid="schedule-run-nightly"])) |> render_click() =~
               ~s(data-testid="schedule-run-modal")

      html = view |> element(~s([data-testid="schedule-run-cancel"])) |> render_click()

      refute html =~ ~s(data-testid="schedule-run-modal")
      assert FakeController.calls(node, {Schedule, :run}) == []
    end

    test "names the relay it started and links to it", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      FakeController.set(
        node,
        {Schedule, :run},
        {:ok, %{relay_id: "nightly@manual-1", outcome: :spawned}}
      )

      {:ok, view, _html} = live(conn, ~p"/schedules")
      view |> element(~s([data-testid="schedule-run-nightly"])) |> render_click()
      html = view |> element(~s([data-testid="schedule-run-confirm"])) |> render_click()

      # A second click finds the confirmation closed and fires nothing more.
      render_click(view, "run_now", %{"name" => "nightly"})

      assert [["nightly", _ctx]] = FakeController.calls(node, {Schedule, :run})
      assert html =~ ~r{href="/namespaces/default/relays/nightly(@|%40)manual-1"}
      assert html =~ "nightly ran now and started"
    end

    test "an instance already running is said so, and none was started", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [entry()])

      FakeController.set(
        node,
        {Schedule, :run},
        {:ok, %{relay_id: nil, outcome: :already_running}}
      )

      {:ok, view, _html} = live(conn, ~p"/schedules")
      view |> element(~s([data-testid="schedule-run-nightly"])) |> render_click()
      html = view |> element(~s([data-testid="schedule-run-confirm"])) |> render_click()

      assert html =~ "has an instance running already, so none was started"
      refute html =~ ~s(data-testid="schedule-ran-link")
    end

    test "a refused run shows the error and names no relay", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      FakeController.set(
        node,
        {Schedule, :run},
        {:error,
         Flezha.Error.new("schedule.not_found", "no schedule nightly", "flz schedule list")}
      )

      {:ok, view, _html} = live(conn, ~p"/schedules")
      view |> element(~s([data-testid="schedule-run-nightly"])) |> render_click()
      html = view |> element(~s([data-testid="schedule-run-confirm"])) |> render_click()

      assert html =~ "schedule.not_found"
      assert html =~ "flz schedule list"
      refute html =~ ~s(data-testid="schedule-ran-link")
    end
  end
end
