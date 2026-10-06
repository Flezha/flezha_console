defmodule FlezhaUiWeb.NamespaceAdminTest do
  @moduledoc """
  Namespaces as declared objects: the controller's catalog with each
  namespace's record, quota meters against live counters, role bindings, and
  the three mutations.

  A declared namespace with no hub, a breached quota and a refused create are
  all states a working dev stack will not hold, which is why they live here.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.AuthZ.TokenStore
  alias Flezha.Service.Namespace
  alias Flezha.Service.Relay

  defp record(name, quotas \\ %{}) do
    %{
      name: name,
      quotas:
        Map.merge(
          %{
            max_relays: 100,
            max_cells_per_relay: 1_024,
            max_mailbox_bytes_total: 268_435_456,
            max_message_rate_per_second: 100_000,
            max_state_bytes: 107_374_182_400,
            max_runners: 32
          },
          quotas
        ),
      created_at: System.system_time(:second),
      created_by_principal: "root"
    }
  end

  defp with_catalog(node, opts) do
    catalog =
      Enum.map(opts[:running] || [], &%{namespace: &1, running: true}) ++
        Enum.map(opts[:cold] || [], &%{namespace: &1, running: false})

    FakeController.set(node, {Relay, :list_namespaces}, {:ok, catalog})
    FakeController.set(node, {Namespace, :list}, {:ok, opts[:records] || []})

    if get = opts[:get], do: FakeController.set(node, {Namespace, :get}, get)
  end

  describe "the listing reads the catalog with each record" do
    test "a declared namespace with a hub is listed once, as running", %{conn: conn, node: node} do
      with_catalog(node, records: [record("default")], running: ["default"])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespace-row-default")
      assert html =~ "declared &amp; running"
    end

    test "a declared namespace with no hub is listed with zero counts", %{conn: conn, node: node} do
      with_catalog(node, records: [record("cold")], cold: ["cold"])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ "declared, no hub"
      # Zero, not blank.
      assert html =~ ~r/namespace-relays-cold[^>]*>\s*0\s*</
      assert html =~ ~r/namespace-runners-cold[^>]*>\s*0\s*</
    end

    test "a running namespace with no record is marked undeclared", %{conn: conn, node: node} do
      with_catalog(node, records: [], running: ["stray"])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ "running, undeclared"
    end

    test "records the controller cannot answer leave the namespaces listed", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"])

      FakeController.set(
        node,
        {Namespace, :list},
        FakeController.error("internal.uncatalogued")
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="declarations-unavailable")
      assert html =~ ~s(data-testid="namespace-row-default")
    end

    test "a caller bound to one namespace reads its own record with get/2", %{
      conn: conn,
      node: node
    } do
      token = "flzt_team_#{System.unique_integer([:positive])}"
      System.put_env("FLEZHA_TOKEN", token)
      on_exit(fn -> System.delete_env("FLEZHA_TOKEN") end)

      FakeController.set(
        node,
        {TokenStore, :verify},
        {:ok, %{principal: "team-ops", namespace: "team", role: :ops, expires_at: :never}}
      )

      with_catalog(node, running: ["team"], get: {:ok, record("team", %{max_relays: 3})})

      FakeController.set(
        node,
        {Namespace, :list},
        FakeController.error("authz.namespace_mismatch")
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ "declared &amp; running"
      refute html =~ ~s(data-testid="declarations-unavailable")
      calls = FakeController.calls(node, {Namespace, :get})
      assert calls != []
      assert Enum.all?(calls, &match?(["team", %{source: :ui, namespace: "team"}], &1))
    end

    test "a breach is visible without opening the namespace", %{conn: conn, node: node} do
      with_catalog(node, records: [record("full", %{max_relays: 2})], running: ["full"])
      FakeController.set(node, {Namespace, :quota}, {:ok, 2})

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespace-breach-full")
    end
  end

  describe "quota meters" do
    test "every counter kind is shown against the limit that governs it", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})
      FakeController.set(node, {Namespace, :quota}, {:ok, 7})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "quotas")

      assert html =~ ~s(data-testid="quota-relays")
      assert html =~ ~s(data-testid="quota-cells")
      assert html =~ ~s(data-testid="quota-runners")
      assert html =~ "of 100"
      assert html =~ "of 1024"
    end

    test "a kind with no limit says so and draws no meter", %{conn: conn, node: node} do
      with_catalog(node,
        running: ["default"],
        get: {:ok, %{record("default") | quotas: %{max_relays: 100}}}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "quotas")

      assert html =~ ~s(data-testid="quota-unset-disk_bytes")
      assert html =~ "no limit applies"
    end

    test "a counter at its limit is marked breached and opens the section", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"], get: {:ok, record("default", %{max_relays: 5})})
      FakeController.set(node, {Namespace, :quota}, {:per_arg, 1, %{relays: {:ok, 5}}, {:ok, 0}})

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="quota-breached-relays")
      refute html =~ ~s(data-testid="quota-breached-runners")
    end

    test "an undeclared namespace states that no limits apply", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert open_section(view, "quotas") =~ ~s(data-testid="namespace-undeclared")
    end
  end

  describe "mutations" do
    test "creating sends the name and only the overrides given", %{conn: conn, node: node} do
      with_catalog(node, running: [])

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      render_click(view, "open_create", %{})

      render_submit(view, "create", %{
        "create" => %{"name" => "analytics", "max_relays" => "10", "max_runners" => ""}
      })

      assert [["analytics", opts, %{source: :ui}]] =
               FakeController.calls(node, {Namespace, :create})

      assert Keyword.get(opts, :quotas) == %{max_relays: 10}
    end

    test "a refused create shows the controller's message and creates nothing", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: [])

      FakeController.set(
        node,
        {Namespace, :create},
        FakeController.error("namespace.already_exists", "namespace 'analytics' already exists")
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      render_click(view, "open_create", %{})
      html = render_submit(view, "create", %{"create" => %{"name" => "analytics"}})

      assert html =~ ~s(data-testid="create-namespace-error")
      assert html =~ "namespace &#39;analytics&#39; already exists"
    end

    test "a refusal names its code", %{conn: conn, node: node} do
      with_catalog(node, running: [])

      FakeController.set(
        node,
        {Namespace, :create},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      render_click(view, "open_create", %{})
      html = render_submit(view, "create", %{"create" => %{"name" => "analytics"}})

      assert html =~ "refused the namespace create"
      assert html =~ "authz.role_insufficient"
    end

    test "deleting requires the namespace to be named", %{conn: conn, node: node} do
      with_catalog(node, records: [record("doomed")], cold: ["doomed"])

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      render_click(view, "confirm_delete", %{"name" => "doomed"})

      # Confirmed with the wrong name: nothing happens.
      render_change(view, "delete_confirmation_change", %{"confirm" => %{"name" => "nope"}})
      render_click(view, "delete", %{})
      assert FakeController.calls(node, {Namespace, :delete}) == []

      render_change(view, "delete_confirmation_change", %{"confirm" => %{"name" => "doomed"}})
      render_click(view, "delete", %{})
      assert [["doomed", %{source: :ui}]] = FakeController.calls(node, {Namespace, :delete})
    end

    test "dismissing the delete confirmation calls nothing", %{conn: conn, node: node} do
      with_catalog(node, records: [record("doomed")], cold: ["doomed"])

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      render_click(view, "confirm_delete", %{"name" => "doomed"})
      html = render_click(view, "cancel_delete", %{})

      refute html =~ ~s(data-testid="delete-namespace-modal")
      assert FakeController.calls(node, {Namespace, :delete}) == []
    end

    test "saving quotas sends every limit, the edited one changed", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "open_quotas", %{})
      render_change(view, "quota_change", %{"quota" => %{"max_relays" => "250"}})
      render_click(view, "save_quotas", %{})

      assert [["default", sent, %{source: :ui}]] =
               FakeController.calls(node, {Namespace, :set_quotas})

      assert sent == %{record("default").quotas | max_relays: 250}
    end

    test "a refused quota change is stated on the form", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :set_quotas},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "open_quotas", %{})
      html = render_click(view, "save_quotas", %{})

      assert html =~ ~s(data-testid="quota-error")
      assert html =~ "authz.role_insufficient"
      refute html =~ "Quotas updated."
    end
  end

  describe "role bindings" do
    test "a principal is listed once with every role it holds", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :roles},
        {:ok, [%{principal: "alice", namespace: "default", roles: [:ops, :viewer]}]}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "role-bindings")

      assert html =~ ~s(data-testid="role-binding-alice")
      assert html =~ "ops, viewer"
    end

    test "an empty binding list names the command that adds one", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "role-bindings")

      assert html =~ ~s(data-testid="role-bindings-empty")
      assert html =~ "flz role bind"
    end
  end
end
