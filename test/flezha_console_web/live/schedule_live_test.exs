defmodule FlezhaConsoleWeb.ScheduleLiveTest do
  @moduledoc """
  The schedules screen, against a controller whose hub can be made to disagree
  with its store.

  The browser suite covers creating and removing against a healthy controller.
  The state it cannot produce is the one this screen exists to distinguish: an
  entry the store holds but no node fires.
  """

  use FlezhaConsoleWeb.LiveCase

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
    view |> element(~s([data-testid="schedule-new-btn"])) |> render_click()
    view
  end

  defp submit(view, fields) do
    view
    |> form(~s(form[phx-submit="create"]), %{"schedule" => fields})
    |> render_submit()
  end

  defp change(view, fields) do
    view
    |> form(~s(form[phx-change="form_change"]), %{"schedule" => fields})
    |> render_change()
  end

  defp confirm_remove(view) do
    view |> element(~s([data-testid="schedule-remove-nightly"])) |> render_click()
    view |> element(~s([data-testid="schedule-remove-confirm"])) |> render_click()
  end

  defp adds(node), do: FakeController.calls(node, {Schedule, :add})

  describe "listing" do
    test "an entry a node fires reads as active, with its next fire", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      {:ok, view, html} = live(conn, ~p"/schedules")

      status = view |> element(~s([data-testid="schedule-status-nightly"])) |> render()
      assert status =~ ~r/>\s*Active\s*</
      assert status =~ "A node holds this schedule"
      assert html =~ "echo_steps"

      assert view |> element(~s([data-testid="schedule-next-fire-nightly"])) |> render() =~
               "2031-06-01"
    end

    test "an entry that has fired shows when, how it went and the relay it started", %{
      conn: conn,
      node: node
    } do
      last_fire = %{at: ~U[2031-05-31 03:00:00.057538Z], outcome: :ok, instance_id: "nightly@1"}

      with_entries(node, [
        entry(%{last_fire: last_fire, created_at: "2026-10-01T09:00:00.123456Z"})
      ])

      {:ok, _view, html} = live(conn, ~p"/schedules")

      assert html =~ "2031-05-31 03:00:00"
      assert text_of(html, ~s([data-testid="schedule-created-nightly"])) =~ "2026-10-01 09:00:00"

      assert html =~
               ~r{href="/namespaces/default/relays/nightly%401"[^>]*data-testid="schedule-last-relay-nightly"[^>]*>\s*started}
    end

    test "a fire being retried says so, with the reason, in the warning tone", %{
      conn: conn,
      node: node
    } do
      last_fire = %{
        at: ~U[2031-05-31 03:00:00Z],
        outcome: {:retrying, "no runner serves echo_steps"},
        instance_id: "nightly@2031-05-31T03:00:00Z"
      }

      with_entries(node, [entry(%{last_fire: last_fire})])

      {:ok, view, _html} = live(conn, ~p"/schedules")

      cell = view |> element(~s([data-testid="schedule-last-fire-nightly"])) |> render()
      assert cell =~ "retrying: no runner serves echo_steps"
      assert cell =~ "fcon-tone-warning"
    end

    test "a dormant entry reads as dormant, with no next fire", %{conn: conn, node: node} do
      with_entries(node, [entry(%{next_fire: nil, dormant?: true})])

      {:ok, view, html} = live(conn, ~p"/schedules")

      status = view |> element(~s([data-testid="schedule-status-nightly"])) |> render()
      assert status =~ ~r/>\s*Dormant\s*</
      assert text_of(html, ~s([data-testid="schedule-next-fire-nightly"])) == "—"
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
  end

  describe "creating" do
    setup %{node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        {:ok, [%{namespace: "default", running: true}]}
      )

      FakeController.set(
        node,
        {Fleet, :factories},
        {:ok, [%{id: "echo_steps", description: "echoes", run: :steps}]}
      )

      :ok
    end

    test "stores and arms it in one call, and reports it", %{conn: conn, node: node} do
      view = open_form(conn)

      html = submit(view, valid_form())

      assert html =~ "Schedule nightly created."
      assert [[fields, %{source: :ui}]] = adds(node)
      assert fields[:name] == "nightly"
      assert fields[:factory_id] == "echo_steps"
      assert fields[:namespace] == "default"
    end

    test "requires the fields the controller requires", %{conn: conn, node: node} do
      view = open_form(conn)

      html = submit(view, valid_form(%{"name" => ""}))

      assert html =~ ~s(data-testid="schedule-form-error")
      assert html =~ "Required: Name."
      assert adds(node) == []
    end

    test "rejects init values that are not JSON before calling the controller", %{
      conn: conn,
      node: node
    } do
      view = open_form(conn)

      html = submit(view, valid_form(%{"init_values" => "{nope"}))

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

      html = submit(view, valid_form(%{"timezone" => "Mars/Olympus_Mons"}))

      assert html =~ "is not an IANA time zone"
      assert html =~ ~s(data-testid="schedule-form-modal")
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
                %{
                  id: "default_steps",
                  description: "spawns things",
                  run: :steps,
                  runners: ["runner-a"]
                },
                %{
                  id: "default_flow",
                  description: "forwards things",
                  run: :flow,
                  runners: ["runner-a"]
                }
              ]},
           "staging" =>
             {:ok,
              [
                %{
                  id: "staging_steps",
                  description: "spawns things",
                  run: :steps,
                  runners: ["runner-a"]
                }
              ]}
         }, {:ok, []}}
      )

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
      html = conn |> open_form() |> render()
      refute html =~ "(no runner)"

      FakeController.set(
        node,
        {Fleet, :factories},
        {:ok, [%{id: "default_steps", description: "spawns things", run: :steps, runners: []}]}
      )

      assert conn |> open_form() |> render() =~ "(no runner)"
    end

    test "changing the namespace offers the new namespace's factories", %{conn: conn} do
      view = open_form(conn)

      html = change(view, %{"namespace" => "staging"})

      assert html =~ "staging_steps"
      refute html =~ "default_steps"
    end

    test "a factory the new namespace does not register stops being chosen", %{conn: conn} do
      view = open_form(conn)

      change(view, %{"namespace" => "staging", "factory_id" => "default_steps"})

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

      submit(view, valid_form())

      assert [[fields, _ctx]] = adds(node)
      assert fields[:namespace] == "default"
      assert fields[:factory_id] == "echo_steps"
    end

    test "opening the form is what reads the catalog, not the tick", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/schedules")
      send(view.pid, :refresh)
      _rendered = render(view)

      assert FakeController.calls(node, {Fleet, :factories}) == []

      view |> element(~s([data-testid="schedule-new-btn"])) |> render_click()

      assert [["default", %{source: :ui}]] = FakeController.calls(node, {Fleet, :factories})
    end

    test "a scoped screen's form opens aimed at its namespace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/staging/schedules")
      html = view |> element(~s([data-testid="schedule-new-btn"])) |> render_click()

      assert html =~ "staging_steps"
    end
  end

  describe "removing" do
    setup %{node: node} do
      with_entries(node, [entry()])
      :ok
    end

    test "removes and retracts in one call", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/schedules")

      assert confirm_remove(view) =~ "Schedule nightly removed."

      assert [["nightly", %{source: :ui}]] = FakeController.calls(node, {Schedule, :remove})
    end

    test "reports a refused removal", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Schedule, :remove},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/schedules")

      assert confirm_remove(view) =~ "authz.role_insufficient"
    end
  end

  describe "running a schedule now" do
    test "names the relay it started, and a forged second click fires nothing more", %{
      conn: conn,
      node: node
    } do
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
