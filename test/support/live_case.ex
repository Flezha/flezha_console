defmodule FlezhaUiWeb.LiveCase do
  @moduledoc """
  Case template for LiveView tests that need a controller to answer them.

  Boots one peer node per test module standing in for the controller (see
  `FakeController`) and logs a user in, so a test only has to say what the
  controller should answer and then drive the screen.

  Never concurrent, and one peer per module rather than per test:
  `NodeManager.connected_node/0` reads `Node.list(:connected)`, which is global
  VM state, so two modules with their own peers would each be able to answer as
  the other's controller. `PeerNode.start!/2` disconnects stale peers for the
  same reason.

  Tagged `:distributed`, so `mix test --exclude distributed` still gives a fast
  inner loop with no peer boots.

      use FlezhaUiWeb.LiveCase

      test "renders the namespaces", %{conn: conn, node: node} do
        FakeController.set_fleet(node, namespaces: ["default"])
        {:ok, _view, html} = live(conn, ~p"/namespaces")
        assert html =~ "default"
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use FlezhaUiWeb.ConnCase, async: false

      import Phoenix.LiveViewTest

      import FlezhaUiWeb.LiveCase,
        only: [
          open_section: 2,
          text_of: 2,
          tick: 1,
          enforce_operations: 3,
          grant_operations: 3
        ]

      alias FlezhaUi.PeerNode
      alias FlezhaUi.Service.NodeManager

      @moduletag :distributed

      setup_all do
        PeerNode.setup_controller()
      end

      setup %{conn: conn, node: node} do
        # Canned answers are node-global, so without this one test's setup is
        # the next one's surprise.
        FakeController.reset(node)

        user = FlezhaUi.AccountsFixtures.user_fixture()
        %{conn: log_in_user(conn, user), user: user}
      end
    end
  end

  @doc """
  Unfolds one of a long screen's sections and answers the screen with it open.

  The lower panels of the relay and namespace screens start folded, so a
  test that reads one says so first — the same click an operator makes.
  """
  def open_section(view, key) do
    view
    |> Phoenix.LiveViewTest.element(~s([data-testid="section-toggle-#{key}"]))
    |> Phoenix.LiveViewTest.render_click()
  end

  @doc """
  One refresh tick of a screen that shows rates, answered with the render.

  A rate divides a delta by the time since the last reading, so the last
  reading is moved a second into the past rather than waited for.
  """
  def tick(view) do
    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      %{state | socket: update_in(socket.assigns.topology_state.prev_at, &(&1 && &1 - 1_000))}
    end)

    send(view.pid, :refresh)
    Phoenix.LiveViewTest.render(view)
  end

  @doc """
  The text of what `selector` matches in `html`, its whitespace collapsed as a
  browser shows it.
  """
  def text_of(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Binds `user` to a token that verifies as `identity` under an enforced
  posture: the only setup in which a screen's controls follow the operations
  whoami grants (`grant_operations/3`). `identity` is `%{principal:,
  namespace:, role:}`.
  """
  def enforce_operations(node, user, identity) do
    token = "flzt_#{System.unique_integer([:positive])}"
    {:ok, _user} = FlezhaUi.Accounts.update_user_flezha_token(user, token)
    FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, :enforced)

    FakeController.set(
      node,
      {Flezha.AuthZ.TokenStore, :verify},
      {:ok, Map.put(identity, :expires_at, :never)}
    )
  end

  @doc "Makes whoami answer `identity` with exactly `operations` granted."
  def grant_operations(node, identity, operations) do
    FakeController.set(
      node,
      {Flezha.Service.Namespace, :whoami},
      {:ok, Map.put(identity, :operations, operations)}
    )
  end
end
