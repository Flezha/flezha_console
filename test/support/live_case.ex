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
        FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default"]})
        {:ok, _view, html} = live(conn, ~p"/namespaces")
        assert html =~ "default"
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use FlezhaUiWeb.ConnCase, async: false

      import Phoenix.LiveViewTest

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
end
