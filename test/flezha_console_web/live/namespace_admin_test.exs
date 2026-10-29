defmodule FlezhaConsoleWeb.NamespaceAdminTest do
  @moduledoc """
  Namespaces as declared objects: the controller's catalog with each
  namespace's record, quota meters against live counters, role bindings and
  tokens, and the create and quota mutations.

  A declared namespace with no hub, a breached quota and a refused create are
  all states a working dev stack will not hold, which is why they live here.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Admin
  alias Flezha.Service.Namespace
  alias Flezha.Service.Relay
  alias FlezhaConsole.TestEnv

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
      Enum.map(opts[:running] || [], &%{namespace: &1, running: true, nodes: [:"flezha@node-a"]}) ++
        Enum.map(opts[:cold] || [], &%{namespace: &1, running: false, nodes: []})

    FakeController.set(
      node,
      {Relay, :list_namespaces},
      FakeController.rows(catalog, opts[:unreachable] || [])
    )

    FakeController.set(node, {Namespace, :list}, {:ok, opts[:records] || []})

    if get = opts[:get], do: FakeController.set(node, {Namespace, :get}, get)
  end

  describe "the listing reads the catalog with each record" do
    test "a namespace whose hub runs only on another controller is listed as running", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.rows([%{namespace: "second", running: true, nodes: [:"flezha@node-b"]}])
      )

      FakeController.set(node, {Namespace, :list}, {:ok, [record("second")]})

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespace-row-second")
      assert html =~ "Declared and running"
      refute html =~ "Declared, no hub running"
    end

    test "an empty listing missing a controller says so, and not that nothing exists", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, unreachable: ["flezha@node-b"])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert length(testids(html, ~s([data-testid="partial-answer"]))) == 1
      assert text_of(html, ~s([data-testid="partial-answer"])) =~ "flezha@node-b did not"

      assert text_of(html, ~s([data-testid="partial-empty"])) ==
               "No namespace was found on the controllers that answered."

      refute html =~ ~s(data-testid="namespaces-empty")
    end

    test "a full answer shows no partial-answer notice", %{conn: conn, node: node} do
      with_catalog(node, records: [record("default")], running: ["default"])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      refute html =~ ~s(data-testid="partial-answer")
    end

    test "a declared namespace with a hub is listed once, as running", %{conn: conn, node: node} do
      with_catalog(node, records: [record("default")], running: ["default"])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespace-row-default")
      assert html =~ "Declared and running"
    end

    test "a declared namespace with no hub is listed with zero counts", %{conn: conn, node: node} do
      with_catalog(node, records: [record("cold")], cold: ["cold"])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ "Declared, no hub running"
      # Zero, not blank.
      assert html =~ ~r/namespace-relays-cold[^>]*>\s*0 relays\s*</
      assert html =~ ~r/namespace-runners-cold[^>]*>\s*0 runners\s*</
    end

    test "a running namespace with no record is marked undeclared", %{conn: conn, node: node} do
      with_catalog(node, records: [], running: ["stray"])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ "Running, undeclared"
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
      TestEnv.put_system("FLEZHA_TOKEN", token)

      FakeController.set(
        node,
        {Admin, :context},
        {:ok, %{principal: "team-ops", namespace: "team", role: :ops, source: :ui}}
      )

      with_catalog(node, running: ["team"], get: {:ok, record("team", %{max_relays: 3})})

      FakeController.set(
        node,
        {Namespace, :list},
        FakeController.error("authz.namespace_mismatch")
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ "Declared and running"
      refute html =~ ~s(data-testid="declarations-unavailable")
      calls = FakeController.calls(node, {Namespace, :get})
      assert calls != []
      assert Enum.all?(calls, &match?(["team", %{source: :ui, namespace: "team"}], &1))
    end

    test "a breach is visible without opening the namespace", %{conn: conn, node: node} do
      with_catalog(node, records: [record("full", %{max_relays: 2})], running: ["full"])
      FakeController.set(node, {Namespace, :quota}, FakeController.quota_usage(2))

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
      FakeController.set(node, {Namespace, :quota}, FakeController.quota_usage(7))

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

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

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      html = open_section(view, "quotas")

      assert html =~ ~s(data-testid="quota-unset-disk_bytes")
      assert html =~ "No limit applies"
    end

    test "a counter at its limit is marked breached and opens the section", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"], get: {:ok, record("default", %{max_relays: 5})})

      FakeController.set(
        node,
        {Namespace, :quota},
        {:per_arg, 1, %{relays: FakeController.quota_usage(5)}, FakeController.quota_usage(0)}
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="quota-breached-relays")
      refute html =~ ~s(data-testid="quota-breached-runners")
    end

    test "relays on two controllers are counted as one total against the limit", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"], get: {:ok, record("default", %{max_relays: 5})})

      FakeController.set(
        node,
        {Namespace, :quota},
        {:per_arg, 1,
         %{relays: FakeController.quota_usage(5, %{"flezha@node-a": 3, "flezha@node-b": 2})},
         FakeController.quota_usage(0)}
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="quota-breached-relays")
      assert text_of(html, ~s([data-testid="quota-relays"])) =~ "5"
    end

    test "an undeclared namespace states that no limits apply", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"])

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      assert open_section(view, "quotas") =~ ~s(data-testid="namespace-undeclared")
    end
  end

  describe "mutations" do
    test "creating sends the name and only the overrides given", %{conn: conn, node: node} do
      with_catalog(node, running: [])

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      create(view, %{name: "analytics", max_relays: "10", max_runners: ""})

      assert [["analytics", opts, %{source: :ui}]] =
               FakeController.calls(node, {Namespace, :create})

      assert Keyword.get(opts, :quotas) == %{max_relays: 10}
    end

    test "a quota that is not a whole number is named and nothing is created", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: [])

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      html = create(view, %{name: "analytics", max_relays: "-1", max_runners: ""})

      assert html =~ "max_relays must be a whole number of 0 or more."
      assert FakeController.calls(node, {Namespace, :create}) == []
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
      html = create(view, %{name: "analytics"})

      assert html =~ ~s(data-testid="create-namespace-error")
      assert html =~ "namespace <code>analytics</code> already exists"
    end

    test "a refusal names its code", %{conn: conn, node: node} do
      with_catalog(node, running: [])

      FakeController.set(
        node,
        {Namespace, :create},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      html = create(view, %{name: "analytics"})

      assert html =~ "refused the namespace create"
      assert html =~ "authz.role_insufficient"
    end

    test "saving quotas sends every limit, the edited one changed", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      edit_quotas(view, %{max_relays: "250"})
      save_quotas(view)

      assert [["default", sent, %{source: :ui}]] =
               FakeController.calls(node, {Namespace, :set_quotas})

      assert sent == %{record("default").quotas | max_relays: 250}
    end

    test "a limit that is not a whole number is named and nothing is sent", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      edit_quotas(view, %{max_relays: "lots"})
      html = save_quotas(view)

      assert html =~ ~s(data-testid="quota-error")
      assert html =~ "max_relays must be a whole number of 0 or more."
      assert html =~ ~s(data-testid="quota-modal")
      assert FakeController.calls(node, {Namespace, :set_quotas}) == []
    end

    test "a refused quota change is stated on the form", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :set_quotas},
        FakeController.error("authz.role_insufficient")
      )

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      edit_quotas(view, %{})
      html = save_quotas(view)

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

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      html = open_section(view, "access")

      assert html =~ ~s(data-testid="role-binding-alice")
      assert html =~ ~s(data-testid="role-alice-ops")
      assert html =~ ~s(data-testid="role-alice-viewer")
    end

    test "a binding states when it was last bound and by whom, a dash when unknown", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :roles},
        {:ok,
         [
           %{
             principal: "alice",
             namespace: "default",
             roles: [:ops],
             bound_at: System.system_time(:second) - 2 * 3_600,
             bound_by: "admin"
           },
           %{principal: "bob", namespace: "default", roles: [:viewer]}
         ]}
      )

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      html = open_section(view, "access")

      assert text_of(html, ~s([data-testid="binding-bound-alice"])) =~ "2h 0m ago"
      assert text_of(html, ~s([data-testid="binding-by-alice"])) == "admin"
      assert text_of(html, ~s([data-testid="binding-bound-bob"])) == "—"
      assert text_of(html, ~s([data-testid="binding-by-bob"])) == "—"
    end

    test "an empty binding list says none is bound", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      html = open_section(view, "access")

      assert html =~ ~s(data-testid="role-bindings-empty")
    end

    test "a cluster-wide binding is said to reach every namespace", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :roles},
        {:ok, [%{principal: "root", namespace: "_system", roles: [:admin]}]}
      )

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      html = open_section(view, "access")

      assert text_of(html, ~s([data-testid="role-binding-root"])) =~ "Cluster-wide"
    end
  end

  describe "tokens" do
    test "this namespace's tokens are listed, never their values", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :tokens},
        {:ok, [token_row("tok-1"), token_row("tok-2", %{namespace: "staging"})]}
      )

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      html = open_section(view, "access")

      assert html =~ ~s(data-testid="token-tok-1")
      assert html =~ "deploys"
      assert html =~ ~r/data-testid="token-status-tok-1"[^>]*>\s*Active/
      refute html =~ ~s(data-testid="token-tok-2")
      refute html =~ "flzt_"
    end

    test "a token row states when and by whom it was issued, and when it expires", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})
      now = System.system_time(:second)

      FakeController.set(
        node,
        {Namespace, :tokens},
        {:ok,
         [
           token_row("tok-never", %{expires_at: :never}),
           token_row("tok-late", %{expires_at: now + 20 * 86_400}),
           token_row("tok-soon", %{expires_at: now + 86_400}),
           token_row("tok-bare", %{created_at: nil, expires_at: nil, created_by: nil}),
           token_row("tok-gone", %{status: :expired, expires_at: now - 60})
         ]}
      )

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      html = open_section(view, "access")

      assert text_of(html, ~s([data-testid="token-issued-tok-late"])) =~ "3d 0h ago"
      assert text_of(html, ~s([data-testid="token-issuer-tok-late"])) == "admin"
      assert text_of(html, ~s([data-testid="token-expires-tok-late"])) =~ ~r/in (19|20)d/
      assert text_of(html, ~s([data-testid="token-expires-tok-never"])) == "never"

      # Under three days left is a warning; a long way off is not.
      assert html =~ ~r/data-testid="token-expires-tok-soon".*?fcon-tone-warning/s
      refute html =~ ~r/data-testid="token-expires-tok-late"[^<]*<span class="fcon-tone-warning"/

      # Soonest expiry first, never after every token that expires, the
      # unknown last; only active tokens by default, with each status counted.
      assert testids(html, ~s([data-testid="tokens-panel"] tbody tr)) ==
               ["token-tok-soon", "token-tok-late", "token-tok-never", "token-tok-bare"]

      assert text_of(html, ~s([data-testid="token-filter-active"])) =~ "4"
      assert text_of(html, ~s([data-testid="token-filter-expired"])) =~ "1"
      assert text_of(html, ~s([data-testid="token-filter-all"])) =~ "5"

      # A row the controller answered without times still lists, with dashes.
      assert text_of(html, ~s([data-testid="token-issued-tok-bare"])) == "—"
      assert text_of(html, ~s([data-testid="token-issuer-tok-bare"])) == "—"

      html = view |> element(~s([data-testid="token-filter-expired"])) |> render_click()

      assert testids(html, ~s([data-testid="tokens-panel"] tbody tr)) == ["token-tok-gone"]
    end
  end

  defp token_row(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        principal: "ci",
        namespace: "default",
        role: :app,
        label: "deploys",
        status: :active,
        created_at: System.system_time(:second) - 3 * 86_400,
        expires_at: System.system_time(:second) + 27 * 86_400,
        revoked_at: nil,
        created_by: "admin"
      },
      overrides
    )
  end

  defp create(view, fields) do
    view |> element(~s([data-testid="create-namespace-btn"])) |> render_click()

    view
    |> form(~s([data-testid="create-namespace-form"]), create: fields)
    |> render_submit()
  end

  defp edit_quotas(view, limits) do
    view |> element(~s([data-testid="edit-quotas-btn"])) |> render_click()
    view |> form(~s(form[phx-change="quota_change"]), quota: limits) |> render_change()
  end

  defp save_quotas(view) do
    view |> element(~s([data-testid="quota-save"])) |> render_click()
    render_async(view)
  end
end
