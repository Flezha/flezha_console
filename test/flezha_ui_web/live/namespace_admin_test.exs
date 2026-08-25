defmodule FlezhaUiWeb.NamespaceAdminTest do
  @moduledoc """
  Namespaces as declared objects: the union with running hubs, quota meters
  against live counters, and the three mutations.

  A declared namespace with no hub, a breached quota and a refused create are
  all states a working dev stack will not hold, which is why they live here.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.AuthZ.NamespaceStore
  alias Flezha.AuthZ.QuotaCounters
  alias Flezha.AuthZ.RoleStore
  alias Flezha.Service.HubManager

  defp entry(name, quotas \\ %{}) do
    %{
      name: name,
      quotas: Map.merge(%{max_operatives: 100, max_runners: 32}, quotas),
      created_at: System.system_time(:second),
      created_by_principal: "root"
    }
  end

  defp with_store(node, opts) do
    FakeController.set(node, {Flezha, :list_namespaces}, {:ok, opts[:running] || []})
    FakeController.set(node, {NamespaceStore, :list}, opts[:declared] || [])
    FakeController.set(node, {NamespaceStore, :get}, opts[:get] || :error)
    FakeController.set(node, {HubManager, :operative_rows}, opts[:rows] || [])
  end

  describe "the listing unions declared with running" do
    test "a namespace in both sources is listed once, as running", %{conn: conn, node: node} do
      with_store(node, declared: [entry("default")], running: ["default"])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespace-row-default")
      assert html =~ "declared &amp; running"
    end

    test "a declared namespace with no hub is listed with zero counts", %{conn: conn, node: node} do
      with_store(node, declared: [entry("cold")], running: [])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespace-row-cold")
      assert html =~ "declared, no hub"
      assert html =~ ~s(data-testid="namespace-operatives-cold")
      # Zero, not blank.
      assert html =~ ~r/namespace-operatives-cold[^>]*>\s*0\s*</
    end

    test "a running hub with no declaration is marked undeclared", %{conn: conn, node: node} do
      with_store(node, declared: [], running: ["stray"])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespace-row-stray")
      assert html =~ "running, undeclared"
    end

    test "a controller with no namespace store falls back to running hubs", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default"]})

      FakeController.set(
        node,
        {NamespaceStore, :list},
        {:error, {:api_missing, NamespaceStore, :list, 0}}
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="declarations-unavailable")
      assert html =~ ~s(data-testid="namespace-row-default")
    end

    test "a breach is visible without opening the namespace", %{conn: conn, node: node} do
      with_store(node, declared: [entry("full", %{max_operatives: 2})], running: ["full"])
      FakeController.set(node, {QuotaCounters, :get}, 2)

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespace-breach-full")
    end
  end

  describe "quota meters" do
    test "every counter kind is shown against its limit", %{conn: conn, node: node} do
      with_store(node, running: ["default"], get: {:ok, entry("default")})
      FakeController.set(node, {QuotaCounters, :get}, 7)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "quotas")

      assert html =~ ~s(data-testid="quota-panel")
      assert html =~ ~s(data-testid="quota-operatives")
      assert html =~ ~s(data-testid="quota-runners")
      assert html =~ "of 100"
    end

    test "a kind with no limit says so and draws no meter", %{conn: conn, node: node} do
      # `disk_bytes` has no override here, so its limit key is absent.
      with_store(node,
        running: ["default"],
        get: {:ok, %{entry("default") | quotas: %{max_operatives: 100}}}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "quotas")

      assert html =~ ~s(data-testid="quota-unset-disk_bytes")
      assert html =~ "no limit applies"
    end

    test "a counter at its limit is marked breached", %{conn: conn, node: node} do
      with_store(node,
        running: ["default"],
        get: {:ok, entry("default", %{max_operatives: 5})}
      )

      FakeController.set(node, {QuotaCounters, :get}, 5)

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="quota-breached-operatives")
    end

    test "an undeclared namespace states that no limits apply", %{conn: conn, node: node} do
      with_store(node, running: ["default"], get: :error)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "quotas")

      assert html =~ ~s(data-testid="namespace-undeclared")
    end
  end

  describe "mutations" do
    test "creating sends the name and only the overrides given", %{conn: conn, node: node} do
      with_store(node, running: [])

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      render_click(view, "open_create", %{})

      render_submit(view, "create", %{
        "create" => %{"name" => "analytics", "max_operatives" => "10", "max_runners" => ""}
      })

      assert [["analytics", opts]] = FakeController.calls(node, {NamespaceStore, :create})
      assert Keyword.get(opts, :quotas) == %{max_operatives: 10}
    end

    test "a refused create shows the controller's reason and creates nothing", %{
      conn: conn,
      node: node
    } do
      with_store(node, running: [])
      FakeController.set(node, {NamespaceStore, :create}, {:error, :already_exists})

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      render_click(view, "open_create", %{})
      html = render_submit(view, "create", %{"create" => %{"name" => "analytics"}})

      assert html =~ ~s(data-testid="create-namespace-error")
      assert html =~ "already_exists"
    end

    test "a refusal names the required remedy", %{conn: conn, node: node} do
      with_store(node, running: [])

      FakeController.set(
        node,
        {NamespaceStore, :create},
        {:error, {:forbidden, :role_insufficient}}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      render_click(view, "open_create", %{})
      html = render_submit(view, "create", %{"create" => %{"name" => "analytics"}})

      assert html =~ "role does not grant this action"
    end

    test "deleting requires the namespace to be named", %{conn: conn, node: node} do
      with_store(node, declared: [entry("doomed")], running: [])

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      render_click(view, "confirm_delete", %{"name" => "doomed"})

      # Confirmed with the wrong name: nothing happens.
      render_change(view, "delete_confirmation_change", %{"confirm" => %{"name" => "nope"}})
      render_click(view, "delete", %{})
      assert FakeController.calls(node, {NamespaceStore, :delete}) == []

      render_change(view, "delete_confirmation_change", %{"confirm" => %{"name" => "doomed"}})
      render_click(view, "delete", %{})
      assert FakeController.calls(node, {NamespaceStore, :delete}) == [["doomed"]]
    end

    test "dismissing the delete confirmation calls nothing", %{conn: conn, node: node} do
      with_store(node, declared: [entry("doomed")], running: [])

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      render_click(view, "confirm_delete", %{"name" => "doomed"})
      html = render_click(view, "cancel_delete", %{})

      refute html =~ ~s(data-testid="delete-namespace-modal")
      assert FakeController.calls(node, {NamespaceStore, :delete}) == []
    end

    test "saving quotas sends only the kinds that changed", %{conn: conn, node: node} do
      with_store(node,
        running: ["default"],
        get: {:ok, entry("default", %{max_operatives: 100, max_runners: 32})}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "open_quotas", %{})
      render_change(view, "quota_change", %{"quota" => %{"max_operatives" => "250"}})
      render_click(view, "save_quotas", %{})

      assert [["default", %{max_operatives: 250}]] =
               FakeController.calls(node, {NamespaceStore, :set_quotas})
    end
  end

  describe "role bindings" do
    test "bound principals are listed with their roles", %{conn: conn, node: node} do
      with_store(node, running: ["default"], get: {:ok, entry("default")})

      FakeController.set(node, {RoleStore, :list_for_namespace}, [
        %{principal: "alice", namespace: "default", role: :operator}
      ])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "role-bindings")

      assert html =~ ~s(data-testid="role-binding-alice")
      assert html =~ "operator"
    end

    test "an empty binding list names the command that adds one", %{conn: conn, node: node} do
      with_store(node, running: ["default"], get: {:ok, entry("default")})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "role-bindings")

      assert html =~ ~s(data-testid="role-bindings-empty")
      assert html =~ "flz role bind"
    end
  end
end
