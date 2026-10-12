defmodule FlezhaUiWeb.RunnerDropTest do
  @moduledoc """
  Dropping a runner and readmitting its process, from both screens that list
  runners: the cluster screen and a namespace's detail page.

  A drop is gated by `Fleet.drop_runner` and a readmit by
  `Fleet.readmit_runner`, which only apply under an enforced posture with a
  verified token stored on the user, as `RoleGatingTest` sets it up.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.Relay

  @runner %{id: "runner-a", pid: 4242}
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
      {:ok, [%{namespace: "default", running: true}]}
    )

    FakeController.set(node, {Fleet, :runners}, {:ok, [@runner]})
    :ok
  end

  defp grant(node, operations), do: grant_operations(node, @identity, operations)

  defp namespace_screen(conn) do
    {:ok, view, _html} = live(conn, ~p"/namespaces/default")
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

        assert has_element?(view, ~s([data-testid="runner-menu-runner-a"]))
        view |> element(~s([data-testid="drop-runner-runner-a"])) |> render_click()
        dialog = view |> element(~s([data-testid="drop-runner-modal"])) |> render()
        assert dialog =~ "runner-a"
        assert dialog =~ "pid 4242"
        assert dialog =~ "refuses this same"
        assert dialog =~ "fui-btn--danger"

        FakeController.set(node, {Fleet, :runners}, {:ok, []})

        FakeController.set(
          node,
          {Fleet, :dropped_runners},
          {:ok, [%{@mark | stable_id: "stable-a"}]}
        )

        view |> element(~s([data-testid="drop-runner-confirm"])) |> render_click()

        assert [["default", "runner-a", _ctx]] = FakeController.calls(node, {Fleet, :drop_runner})
        refute has_element?(view, ~s([data-testid="drop-runner-modal"]))
        refute has_element?(view, ~s([data-testid="runner-runner-a"]))

        mark = view |> element(~s([data-testid="runner-mark-stable-a"])) |> render()
        assert mark =~ "fui-badge--negative"
        assert mark =~ "5151"
      end

      test "a cancelled drop calls nothing", %{conn: conn, node: node} do
        grant(node, ["Fleet.runners", "Fleet.drop_runner"])
        view = unquote(open)(conn)

        view |> element(~s([data-testid="drop-runner-runner-a"])) |> render_click()
        view |> element(~s([data-testid="drop-runner-cancel"])) |> render_click()

        assert FakeController.calls(node, {Fleet, :drop_runner}) == []
        assert has_element?(view, ~s([data-testid="runner-runner-a"]))
      end

      test "a confirmed readmit lifts the mark", %{conn: conn, node: node} do
        FakeController.set(node, {Fleet, :dropped_runners}, {:ok, [@mark]})
        grant(node, ["Fleet.runners", "Fleet.drop_runner", "Fleet.readmit_runner"])
        view = unquote(open)(conn)

        assert has_element?(view, ~s([data-testid="mark-menu-stable-b"]))
        view |> element(~s([data-testid="readmit-runner-stable-b"])) |> render_click()
        FakeController.set(node, {Fleet, :dropped_runners}, {:ok, []})
        view |> element(~s([data-testid="readmit-runner-confirm"])) |> render_click()

        assert [["default", "stable-b", _ctx]] =
                 FakeController.calls(node, {Fleet, :readmit_runner})

        refute has_element?(view, ~s([data-testid="runner-mark-stable-b"]))
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

        refute has_element?(view, ~s([data-testid="runner-runner-a"]))
        assert has_element?(view, ~s([data-testid="runner-mark-stable-b"]))
      end
    end
  end
end
