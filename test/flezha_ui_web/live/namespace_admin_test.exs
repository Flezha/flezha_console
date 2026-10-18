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
  alias FlezhaUi.TestEnv

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

      assert html =~ "Declared and running"
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
      assert html =~ "No limit applies"
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

    test "deleting requires the namespace to be named", %{conn: conn, node: node} do
      with_catalog(node, records: [record("doomed")], cold: ["doomed"])

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      view |> element(~s([data-testid="namespace-delete-doomed"])) |> render_click()

      type_name(view, "nope")
      assert has_element?(view, ~s([data-testid="delete-namespace-confirm"][disabled]))

      type_name(view, "doomed")
      view |> element(~s([data-testid="delete-namespace-confirm"])) |> render_click()
      assert [["doomed", %{source: :ui}]] = FakeController.calls(node, {Namespace, :delete})
    end

    test "a forged delete with the wrong name typed deletes nothing", %{conn: conn, node: node} do
      with_catalog(node, records: [record("doomed")], cold: ["doomed"])

      {:ok, view, _html} = live(conn, ~p"/namespaces")
      view |> element(~s([data-testid="namespace-delete-doomed"])) |> render_click()
      type_name(view, "nope")

      render_click(view, "delete", %{})

      assert FakeController.calls(node, {Namespace, :delete}) == []
      assert has_element?(view, ~s([data-testid="delete-namespace-modal"]))
    end

    test "saving quotas sends every limit, the edited one changed", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
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

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
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

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
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

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "access")

      assert html =~ ~s(data-testid="role-binding-alice")
      assert html =~ ~s(data-testid="binding-menu-alice")
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

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      html = open_section(view, "access")

      assert text_of(html, ~s([data-testid="binding-bound-alice"])) =~ "2h 0m ago"
      assert text_of(html, ~s([data-testid="binding-by-alice"])) == "admin"
      assert text_of(html, ~s([data-testid="binding-bound-bob"])) == "—"
      assert text_of(html, ~s([data-testid="binding-by-bob"])) == "—"
    end

    test "an empty binding list offers the bind control", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "access")

      assert html =~ ~s(data-testid="role-bindings-empty")
      assert html =~ ~s(data-testid="bind-role-empty-btn")
    end

    test "binds a principal to a role in this namespace", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_section(view, "access")

      view |> element(~s([data-testid="bind-role-btn"])) |> render_click()

      FakeController.set(
        node,
        {Namespace, :roles},
        {:ok, [%{principal: "carol", namespace: "default", roles: [:ops]}]}
      )

      html = bind(view, "carol", "ops")

      assert [["carol", "ops", "default", _ctx]] =
               FakeController.calls(node, {Namespace, :bind_role})

      assert html =~ "carol bound as ops in default."
      assert html =~ ~s(data-testid="role-carol-ops")
    end

    test "the role is picked from every role, each saying what it allows", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_section(view, "access")

      html = view |> element(~s([data-testid="bind-role-btn"])) |> render_click()

      for role <- ~w(viewer app ops admin runner spawner stopper) do
        assert html =~ ~s(data-testid="bind-role-role-#{role}")
      end

      assert html =~ "Reads everything in the namespace and changes nothing."
      assert html =~ ~s(placeholder="ops@acme")
    end

    test "a role the controller does not know is refused with its message", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :bind_role},
        FakeController.error(
          "authz.unknown_role",
          "unknown role stopper; roles are admin, ops, app, viewer"
        )
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_section(view, "access")
      view |> element(~s([data-testid="bind-role-btn"])) |> render_click()

      html = bind(view, "carol", "stopper")

      assert html =~ ~s(data-testid="bind-role-error")
      assert html =~ "roles are admin, ops, app, viewer"
    end

    test "unbinding one role asks first and keeps the others", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :roles},
        {:ok, [%{principal: "alice", namespace: "default", roles: [:ops, :viewer]}]}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_section(view, "access")

      html = view |> element(~s([data-testid="unbind-role-alice-ops"])) |> render_click()
      assert html =~ "Its other roles stay."

      FakeController.set(
        node,
        {Namespace, :roles},
        {:ok, [%{principal: "alice", namespace: "default", roles: [:viewer]}]}
      )

      html = view |> element(~s([data-testid="unbind-role-confirm"])) |> render_click()

      assert [["alice", "ops", _ctx]] = FakeController.calls(node, {Namespace, :unbind_role})
      assert html =~ ~s(data-testid="role-alice-viewer")
      refute html =~ ~s(data-testid="role-alice-ops")
    end

    test "removing a whole binding unbinds with no role", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :roles},
        {:ok, [%{principal: "alice", namespace: "default", roles: [:ops]}]}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_section(view, "access")

      html = view |> element(~s([data-testid="unbind-binding-alice"])) |> render_click()
      assert html =~ "Remove every role"
      assert text_of(html, ~s([data-testid="unbind-role-modal"])) =~ ~r/holds in\s+default\?/
      refute html =~ ~s(data-testid="unbind-cluster-wide")

      FakeController.set(node, {Namespace, :roles}, {:ok, []})
      html = view |> element(~s([data-testid="unbind-role-confirm"])) |> render_click()

      assert [["alice", nil, _ctx]] = FakeController.calls(node, {Namespace, :unbind_role})
      refute html =~ ~s(data-testid="role-binding-alice")
    end

    test "a cluster-wide binding is said to reach every namespace", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :roles},
        {:ok, [%{principal: "root", namespace: "_system", roles: [:admin]}]}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_section(view, "access")

      html = view |> element(~s([data-testid="unbind-binding-root"])) |> render_click()

      assert text_of(html, ~s([data-testid="unbind-role-modal"])) =~ ~r/holds in\s+_system\?/
      assert html =~ ~s(data-testid="unbind-cluster-wide")
    end
  end

  describe "tokens" do
    @secret "flzt_issued_secret_value"

    test "this namespace's tokens are listed, never their values", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})

      FakeController.set(
        node,
        {Namespace, :tokens},
        {:ok, [token_row("tok-1"), token_row("tok-2", %{namespace: "staging"})]}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      html = open_section(view, "access")

      assert html =~ ~s(data-testid="token-tok-1")
      assert html =~ ~s(data-testid="token-menu-tok-1")
      assert html =~ "deploys"
      assert html =~ ~r/data-testid="token-status-tok-1"[^>]*>\s*Active/
      refute html =~ ~s(data-testid="token-tok-2")
      refute html =~ "flzt_"
    end

    test "an issued token is shown once, with a copy control, and dropped on close", %{
      conn: conn,
      node: node
    } do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_issue(view)

      html = issue(view, %{principal: "ci", role: "app", ttl: "3600", label: "deploys"})

      assert [["ci", "default", "app", [ttl: 3600, label: "deploys"], _ctx]] =
               FakeController.calls(node, {Namespace, :issue_token})

      assert html =~ ~s(data-testid="issued-token-value")
      assert html =~ @secret
      assert html =~ ~s(data-testid="issued-token-copy")
      assert html =~ "shown once"

      html = view |> element(~s([data-testid="issued-token-done"])) |> render_click()

      refute html =~ @secret

      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               @secret
    end

    test "never is a lifetime", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_issue(view)

      issue(view, %{principal: "ci", role: "viewer", ttl: "never", label: ""})

      assert [["ci", "default", "viewer", [ttl: "never"], _ctx]] =
               FakeController.calls(node, {Namespace, :issue_token})
    end

    test "an invalid lifetime is named and nothing is issued", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_issue(view)

      for ttl <- ["0", "-5", "soon", ""] do
        html = issue(view, %{principal: "ci", role: "app", ttl: ttl})

        assert html =~ "The lifetime must be a positive number of seconds or never."
      end

      assert FakeController.calls(node, {Namespace, :issue_token}) == []
    end

    test "the issued token reaches no log line", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          {:ok, view, _html} = live(conn, ~p"/namespaces/default")
          open_issue(view)

          html = issue(view, %{principal: "ci", role: "app", ttl: "60"})

          assert html =~ @secret
          view |> element(~s([data-testid="issued-token-done"])) |> render_click()
        end)

      assert log =~ "issue_token"
      refute log =~ @secret
    end

    test "a revocation asks first, and the token then lists as revoked", %{conn: conn, node: node} do
      with_catalog(node, running: ["default"], get: {:ok, record("default")})
      FakeController.set(node, {Namespace, :tokens}, {:ok, [token_row("tok-1")]})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_section(view, "access")

      html = view |> element(~s([data-testid="revoke-token-tok-1"])) |> render_click()
      assert html =~ ~s(data-testid="revoke-token-modal")

      FakeController.set(
        node,
        {Namespace, :tokens},
        {:ok,
         [token_row("tok-1", %{status: :revoked, revoked_at: System.system_time(:second) - 5})]}
      )

      html = view |> element(~s([data-testid="revoke-token-confirm"])) |> render_click()

      assert [["tok-1", _ctx]] = FakeController.calls(node, {Namespace, :revoke_token})
      # It leaves the Active listing and is counted, and listed, under Revoked.
      refute html =~ ~s(data-testid="token-tok-1")
      assert text_of(html, ~s([data-testid="token-filter-revoked"])) =~ "1"

      html = view |> element(~s([data-testid="token-filter-revoked"])) |> render_click()
      assert html =~ ~r/data-testid="token-status-tok-1"[^>]*>\s*Revoked/
      assert text_of(html, ~s([data-testid="token-revoked-tok-1"])) =~ "5 s ago"
      refute html =~ ~s(data-testid="revoke-token-tok-1")
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

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      html = open_section(view, "access")

      assert text_of(html, ~s([data-testid="token-issued-tok-late"])) =~ "3d 0h ago"
      assert text_of(html, ~s([data-testid="token-issuer-tok-late"])) == "admin"
      assert text_of(html, ~s([data-testid="token-expires-tok-late"])) =~ ~r/in (19|20)d/
      assert text_of(html, ~s([data-testid="token-expires-tok-never"])) == "never"

      # Under three days left is a warning; a long way off is not.
      assert html =~ ~r/data-testid="token-expires-tok-soon".*?fui-tone-warning/s
      refute html =~ ~r/data-testid="token-expires-tok-late"[^<]*<span class="fui-tone-warning"/

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

  defp type_name(view, name) do
    view
    |> form(~s(form[phx-change="delete_confirmation_change"]), confirm: %{name: name})
    |> render_change()
  end

  defp edit_quotas(view, limits) do
    view |> element(~s([data-testid="edit-quotas-btn"])) |> render_click()
    view |> form(~s(form[phx-change="quota_change"]), quota: limits) |> render_change()
  end

  defp save_quotas(view),
    do: view |> element(~s([data-testid="quota-save"])) |> render_click()

  defp bind(view, principal, role) do
    view
    |> form(~s(form[phx-submit="bind_role"]), binding: %{principal: principal, role: role})
    |> render_submit()
  end

  defp issue(view, fields),
    do: view |> form(~s(form[phx-submit="issue_token"]), token: fields) |> render_submit()

  # The tokens sit in the folded access section.
  defp open_issue(view) do
    unless has_element?(view, ~s([data-testid="issue-token-btn"])),
      do: open_section(view, "access")

    html = view |> element(~s([data-testid="issue-token-btn"])) |> render_click()
    # The role is picked from the roles, never typed.
    assert html =~ ~s(data-testid="issue-token-role")
    assert html =~ ~s(data-testid="issue-token-role-viewer")
    html
  end
end
