defmodule FlezhaUiWeb.ScheduleLiveTest do
  @moduledoc """
  The schedules screen, against a controller whose hub can be made to disagree
  with its store.

  The browser suite covers creating, arming, and removing against a healthy
  controller. The state it cannot produce is the one this screen exists to
  distinguish: an entry the store holds but the hub never armed.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Runner.FleetManager
  alias Flezha.Schedule.Cron
  alias Flezha.Schedule.Hub
  alias Flezha.Schedule.Store

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        name: "nightly",
        cron: "0 3 * * *",
        timezone: "Etc/UTC",
        namespace: "default",
        factory_id: "echo_workflow"
      },
      overrides
    )
  end

  defp valid_form(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "nightly",
        "cron" => "0 3 * * *",
        "timezone" => "Etc/UTC",
        "namespace" => "default",
        "factory_id" => "echo_workflow",
        "init_values" => ""
      },
      overrides
    )
  end

  describe "listing" do
    test "renders the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/schedules")

      assert html =~ ~s(data-testid="schedule-empty")
    end

    test "an entry the hub armed reads as armed", %{conn: conn, node: node} do
      FakeController.set(node, {Store, :list}, [entry()])

      FakeController.set(
        node,
        {Hub, :statuses},
        %{"nightly" => %{node: :"flezha@hub-1"}}
      )

      {:ok, _view, html} = live(conn, ~p"/schedules")

      assert html =~ ~s(data-testid="schedule-row-nightly")
      assert html =~ ~s(data-testid="schedule-status-nightly")
      assert html =~ "Armed"
      assert html =~ "echo_workflow"
    end

    test "an entry the hub never armed is distinguished, not left blank", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Store, :list}, [entry()])
      FakeController.set(node, {Hub, :statuses}, %{})

      {:ok, _view, html} = live(conn, ~p"/schedules")

      # The whole point of joining store and hub: a persisted entry that is not
      # running must not read as if it were.
      assert html =~ ~s(data-testid="schedule-status-nightly")
      assert html =~ "Not armed"
      refute html =~ ">Armed<"
    end

    test "the next fire is computed from the cron, not reported by the hub", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Store, :list}, [entry()])
      FakeController.set(node, {Cron, :next_fire}, {:ok, ~U[2031-06-01 03:00:00Z]})

      {:ok, _view, html} = live(conn, ~p"/schedules")

      assert html =~ ~s(data-testid="schedule-next-fire-nightly")
      assert html =~ "2031-06-01"
    end

    test "a cron the controller cannot parse leaves the cell empty rather than crashing", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Store, :list}, [entry(%{cron: "nonsense"})])
      FakeController.set(node, {Cron, :parse}, {:error, :invalid})

      {:ok, _view, html} = live(conn, ~p"/schedules")

      assert html =~ ~s(data-testid="schedule-row-nightly")
    end

    test "renders the controller's refusal instead of crashing", %{conn: conn, node: node} do
      FakeController.set(node, {Store, :list}, {:error, :timeout})

      {:ok, _view, html} = live(conn, ~p"/schedules")

      assert html =~ "The flezha controller did not answer in time."
    end
  end

  describe "creating" do
    test "persists, then arms, and reports it", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/schedules")
      render_click(view, "open_form", %{})

      html = render_submit(view, "create", %{"schedule" => valid_form()})

      assert html =~ "Schedule nightly created."

      # Persist first, then arm: an entry the hub refuses is still recoverable
      # from the store, whereas an armed job with nothing persisted is not.
      assert [[%{name: "nightly", factory_id: "echo_workflow"}]] =
               FakeController.calls(node, {Store, :add})

      assert [[_entry]] = FakeController.calls(node, {Hub, :assert})
    end

    test "requires the fields the controller requires", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/schedules")
      render_click(view, "open_form", %{})

      html = render_submit(view, "create", %{"schedule" => valid_form(%{"name" => ""})})

      assert html =~ ~s(data-testid="schedule-form-error")
      assert html =~ "Required: Name."
      # Nothing may reach the controller when the form is incomplete.
      assert FakeController.calls(node, {Store, :add}) == []
    end

    test "surfaces an invalid cron without persisting anything", %{conn: conn, node: node} do
      FakeController.set(node, {Store, :add}, {:error, {:invalid_cron, "bad step"}})

      {:ok, view, _html} = live(conn, ~p"/schedules")
      render_click(view, "open_form", %{})

      html = render_submit(view, "create", %{"schedule" => valid_form(%{"cron" => "not a cron"})})

      assert html =~ "Invalid cron expression: bad step"
      assert html =~ ~s(data-testid="schedule-form-modal")
      # Refused by the store means it must never have been armed.
      assert FakeController.calls(node, {Hub, :assert}) == []
    end

    test "surfaces an unknown timezone", %{conn: conn, node: node} do
      FakeController.set(node, {Store, :add}, {:error, {:invalid_timezone, "Mars/Olympus_Mons"}})

      {:ok, view, _html} = live(conn, ~p"/schedules")
      render_click(view, "open_form", %{})

      html =
        render_submit(view, "create", %{
          "schedule" => valid_form(%{"timezone" => "Mars/Olympus_Mons"})
        })

      assert html =~ "Unknown timezone: Mars/Olympus_Mons"
    end

    test "rejects init values that are not JSON before calling the controller", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/schedules")
      render_click(view, "open_form", %{})

      html =
        render_submit(view, "create", %{"schedule" => valid_form(%{"init_values" => "{nope"})})

      assert html =~ "Init Values must be valid JSON."
      assert FakeController.calls(node, {Store, :add}) == []
    end

    test "reports a duplicate name", %{conn: conn, node: node} do
      FakeController.set(node, {Store, :add}, {:error, :already_exists})

      {:ok, view, _html} = live(conn, ~p"/schedules")
      render_click(view, "open_form", %{})

      assert render_submit(view, "create", %{"schedule" => valid_form()}) =~
               "A schedule with that name already exists."
    end
  end

  describe "choosing a target" do
    setup %{node: node} do
      FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default", "staging"]})

      FakeController.set(
        node,
        {Flezha, :list_factories},
        {:per_arg, 0,
         %{
           "default" => {:ok, [%{id: "default_factory", description: "spawns things"}]},
           "staging" => {:ok, [%{id: "staging_factory", description: "spawns things"}]}
         }, {:ok, []}}
      )

      FakeController.set(node, {FleetManager, :runners_for_factory}, {:ok, ["runner-a"]})

      :ok
    end

    test "the namespace field offers the namespaces the token can reach", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/schedules")

      render_click(view, "open_form", %{})

      selector = ~s([data-testid="schedule-input-namespace"] option)
      assert has_element?(view, selector <> ~s([value="default"]))
      assert has_element?(view, selector <> ~s([value="staging"]))
    end

    test "the factory field offers the chosen namespace's factories", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/schedules")

      html = render_click(view, "open_form", %{})

      assert html =~ ~s(data-testid="schedule-input-factory")
      assert html =~ "default_factory — spawns things"
    end

    test "a factory no runner serves is marked as such", %{conn: conn, node: node} do
      FakeController.set(node, {FleetManager, :runners_for_factory}, {:ok, []})

      {:ok, view, _html} = live(conn, ~p"/schedules")

      assert render_click(view, "open_form", %{}) =~ "(no runner)"
    end

    test "changing the namespace offers the new namespace's factories", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/schedules")
      render_click(view, "open_form", %{})

      html =
        render_change(view, "form_change", %{
          "schedule" => valid_form(%{"namespace" => "staging"})
        })

      assert html =~ "staging_factory"
      refute html =~ "default_factory"
    end

    test "a factory the new namespace does not register stops being chosen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/schedules")
      render_click(view, "open_form", %{})

      render_change(view, "form_change", %{
        "schedule" => valid_form(%{"namespace" => "staging", "factory_id" => "default_factory"})
      })

      refute has_element?(view, ~s([data-testid="schedule-input-factory"] option[selected]))
    end

    test "a refused listing leaves both fields typeable and the form submittable", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Flezha, :list_namespaces}, {:error, :node_not_connected})
      FakeController.set(node, {Flezha, :list_factories}, {:error, :timeout})

      {:ok, view, _html} = live(conn, ~p"/schedules")
      html = render_click(view, "open_form", %{})

      assert html =~ "The choices could not be read"

      render_submit(view, "create", %{"schedule" => valid_form()})

      assert [[%{namespace: "default", factory_id: "echo_workflow"}]] =
               FakeController.calls(node, {Store, :add})
    end

    test "opening the form is what reads the catalog, not the tick", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/schedules")
      send(view.pid, :refresh)
      _rendered = render(view)

      assert FakeController.calls(node, {Flezha, :list_factories}) == []

      render_click(view, "open_form", %{})

      assert [["default"]] = FakeController.calls(node, {Flezha, :list_factories})
    end
  end

  describe "removing" do
    setup %{node: node} do
      FakeController.set(node, {Store, :list}, [entry()])
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

      assert FakeController.calls(node, {Store, :remove}) == []
    end

    test "retracts from the hub before deleting from the store", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/schedules")

      render_click(view, "confirm_remove", %{"name" => "nightly"})
      assert render_click(view, "remove", %{"name" => "nightly"}) =~ "Schedule nightly removed."

      # A job left armed against a deleted entry would keep firing with nothing
      # describing it.
      assert FakeController.calls(node, {Hub, :retract}) == [["nightly"]]
      assert FakeController.calls(node, {Store, :remove}) == [["nightly"]]
    end

    test "reports a refused removal", %{conn: conn, node: node} do
      FakeController.set(node, {Store, :remove}, {:error, :not_found})

      {:ok, view, _html} = live(conn, ~p"/schedules")
      render_click(view, "confirm_remove", %{"name" => "nightly"})

      assert render_click(view, "remove", %{"name" => "nightly"}) =~ "Schedule error: :not_found"
    end
  end
end
