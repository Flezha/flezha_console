defmodule FlezhaConsoleWeb.RunnerDropTest do
  @moduledoc """
  Dropping a runner and readmitting its process, from both screens that list
  runners: the cluster screen and a namespace's detail page.

  A drop is gated by `Fleet.drop_runner` and a readmit by
  `Fleet.readmit_runner`, which only apply under an enforced posture with a
  verified token stored on the user, as `RoleGatingTest` sets it up.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.Relay

  @runner FakeController.runner_row("runner-a")
  @mark %{
    stable_id: "stable-b",
    incarnation: "inc-1",
    pid: 5151,
    node: :"flezha@node-a",
    dropped_at: 1_760_000_000,
    dropped_by: "ops@default"
  }

  @identity %{principal: "ops@default", namespace: "default", role: :ops}

  setup %{node: node, user: user} do
    enforce_operations(node, user, @identity)

    FakeController.set(
      node,
      {Relay, :list_namespaces},
      FakeController.rows([%{namespace: "default", running: true}])
    )

    FakeController.set(node, {Fleet, :runners}, {:ok, [@runner]})
    :ok
  end

  defp grant(node, operations), do: grant_operations(node, @identity, operations)

  defp namespace_screen(conn) do
    {view, _html} = live_loaded(conn, ~p"/namespaces/default")
    open_section(view, "runners")
    view
  end

  defp cluster_screen(conn) do
    {:ok, view, _html} = live(conn, ~p"/cluster")
    view
  end

  for {screen, open} <- [namespace: :namespace_screen, cluster: :cluster_screen] do
    describe "on the #{screen} screen" do
      test "Drop and Readmit render only when granted, while marks still list", %{
        conn: conn,
        node: node
      } do
        FakeController.set(node, {Fleet, :dropped_runners}, {:ok, [@mark]})
        grant(node, ["Fleet.runners"])
        view = unquote(open)(conn)

        assert has_element?(view, ~s([data-testid="runner-runner-a"]))
        assert has_element?(view, ~s([data-testid="runner-mark-stable-b"]))
        refute has_element?(view, ~s([data-testid="drop-runner-runner-a"]))
        refute has_element?(view, ~s([data-testid="readmit-runner-stable-b"]))
      end

      test "a confirmed drop calls the controller and the mark appears", %{
        conn: conn,
        node: node
      } do
        grant(node, ["Fleet.runners", "Fleet.drop_runner", "Fleet.readmit_runner"])
        view = unquote(open)(conn)

        view |> element(~s([data-testid="drop-runner-runner-a"])) |> render_click()
        dialog = view |> element(~s([data-testid="drop-runner-modal"])) |> render()
        assert dialog =~ "runner-a"
        # Named by where it is held and for how long, not by an OS pid.
        assert dialog =~ "on flezha@node-a"
        assert dialog =~ ~r/connected 2h \d+m ago/
        assert dialog =~ "refuses this same"

        FakeController.set(node, {Fleet, :runners}, {:ok, []})

        FakeController.set(
          node,
          {Fleet, :dropped_runners},
          {:ok, [%{@mark | stable_id: "stable-a"}]}
        )

        view |> element(~s([data-testid="drop-runner-confirm"])) |> render_click()

        render_async(view)

        assert [["default", "runner-a", _ctx]] = FakeController.calls(node, {Fleet, :drop_runner})
        refute has_element?(view, ~s([data-testid="drop-runner-modal"]))
        refute has_element?(view, ~s([data-testid="runner-runner-a"]))

        mark = text_of(render(view), ~s([data-testid="runner-mark-stable-a"]))
        assert mark =~ "Dropped"
        assert mark =~ "5151"
        assert mark =~ "ops@default"

        # The dropped process keeps retrying and keeps being refused.
        send(view.pid, :refresh)
        render_async(view)
        refute has_element?(view, ~s([data-testid="runner-runner-a"]))
        assert has_element?(view, ~s([data-testid="runner-mark-stable-a"]))
      end

      test "a confirmed readmit lifts the mark", %{conn: conn, node: node} do
        FakeController.set(node, {Fleet, :dropped_runners}, {:ok, [@mark]})
        grant(node, ["Fleet.runners", "Fleet.drop_runner", "Fleet.readmit_runner"])
        view = unquote(open)(conn)

        assert text_of(render(view), ~s([data-testid="runner-mark-stable-b"])) =~ "Dropped"

        view |> element(~s([data-testid="readmit-runner-stable-b"])) |> render_click()

        assert view |> element(~s([data-testid="readmit-runner-modal"])) |> render() =~
                 "stable-b"

        FakeController.set(node, {Fleet, :dropped_runners}, {:ok, []})
        view |> element(~s([data-testid="readmit-runner-confirm"])) |> render_click()
        render_async(view)

        assert [["default", "stable-b", _ctx]] =
                 FakeController.calls(node, {Fleet, :readmit_runner})

        refute has_element?(view, ~s([data-testid="runner-mark-stable-b"]))

        # Readmitted, the same process is admitted on its next retry.
        FakeController.set(node, {Fleet, :runners}, {:ok, [%{@runner | id: "runner-b"}]})
        send(view.pid, :refresh)
        render_async(view)
        assert has_element?(view, ~s([data-testid="runner-runner-b"]))
      end

      test "a refused drop is shown with its code and hint", %{conn: conn, node: node} do
        FakeController.set(
          node,
          {Fleet, :drop_runner},
          {:error,
           Flezha.Error.new(
             "runner.untrackable",
             "this runner has no stable identity",
             "restart it with an SDK that sends one"
           )}
        )

        grant(node, ["Fleet.runners", "Fleet.drop_runner"])
        view = unquote(open)(conn)

        view |> element(~s([data-testid="drop-runner-runner-a"])) |> render_click()
        html = view |> element(~s([data-testid="drop-runner-confirm"])) |> render_click()

        refute has_element?(view, ~s([data-testid="drop-runner-modal"]))
        assert html =~ "runner.untrackable"
        assert html =~ "this runner has no stable identity"
        assert html =~ "restart it with an SDK that sends one"
        assert has_element?(view, ~s([data-testid="runner-runner-a"]))
      end

      test "a drop from elsewhere reloads the runners", %{conn: conn, node: node} do
        grant(node, ["Fleet.runners"])
        view = unquote(open)(conn)
        assert has_element?(view, ~s([data-testid="runner-runner-a"]))

        FakeController.set(node, {Fleet, :runners}, {:ok, []})
        FakeController.set(node, {Fleet, :dropped_runners}, {:ok, [@mark]})
        send(view.pid, {:flezha_event, :runner_dropped, {"default", "stable-b"}})
        render_async(view)

        refute has_element?(view, ~s([data-testid="runner-runner-a"]))
        assert has_element?(view, ~s([data-testid="runner-mark-stable-b"]))
      end
    end
  end
end
