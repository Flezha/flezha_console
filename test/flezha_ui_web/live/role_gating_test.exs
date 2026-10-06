defmodule FlezhaUiWeb.RoleGatingTest do
  @moduledoc """
  Controls follow the operations the bound role is granted, as core's
  `Namespace.whoami/1` lists them: a control whose operation is not granted is
  not rendered, the read-only panels still are, an answer with no list renders
  everything, and the list is read once per token.

  The lists are the ones core's `Admin.catalogue/1` answers for each role.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Namespace
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay
  alias Flezha.Service.Schedule
  alias Flezha.Service.Steps
  alias FlezhaUi.Accounts

  @viewer ~w(AuditLog.list_files AuditLog.read AuditLog.stats AuditLog.tail
             Controller.status Controller.boot_status Controller.cluster_status
             Fleet.factories Fleet.installed_plugins Fleet.provider Fleet.providers Fleet.runners
             Fleet.runners_for_factory Namespace.get Namespace.list Namespace.quota
             Namespace.quota_kinds Namespace.roles Namespace.tokens Namespace.whoami
             PluginManager.enabled Relay.api Relay.cell_state Relay.diagnose Relay.info Relay.list
             Relay.list_namespaces Relay.list_relays Relay.overwatch_state Relay.partition_groups
             Relay.registry Relay.relay_plugins Relay.relay_rows Schedule.list Steps.cells
             Steps.completed_retention_hours Steps.time_travel)

  @ops @viewer ++
         ~w(AuditLog.rotate Dlq.drop Dlq.replay PluginManager.bind PluginManager.disable
            PluginManager.enable PluginManager.unbind PluginManager.update Relay.call
            Relay.call_channel Relay.listen Relay.replay Relay.send Relay.start Relay.stop
            Schedule.add Schedule.remove Schedule.run Steps.inbox Steps.outbox Steps.rescale
            Steps.rewind Steps.rotate)

  setup %{node: node, user: user} do
    token = "flzt_gate_#{System.unique_integer([:positive])}"
    {:ok, _user} = Accounts.update_user_flezha_token(user, token)

    FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, :enforced)

    FakeController.set(
      node,
      {Flezha.AuthZ.TokenStore, :verify},
      {:ok, %{principal: "p@acme", namespace: "default", role: :viewer, expires_at: :never}}
    )

    FakeController.set(node, {Relay, :overwatch_state}, {:ok, %{builder: %{run: :flow}}})
    FakeController.set(node, {Relay, :relay_rows}, {:ok, [FakeController.relay_row("relay_a")]})
    FakeController.set_fleet(node, rows: %{"default" => [FakeController.relay_row("relay_a")]})

    FakeController.set(
      node,
      {Steps, :cells},
      {:ok,
       %{
         relay_class: "relay_a",
         history_retention_hours: 24,
         cells: [
           %{
             relay_class: "relay_a",
             tasklet_id: "orders",
             cell_key: "k1",
             wal_seq: 1,
             snapshot_seq: 1
           }
         ]
       }}
    )

    FakeController.set(
      node,
      {Namespace, :roles},
      {:ok, [%{principal: "alice", namespace: "default", roles: [:ops]}]}
    )

    FakeController.set(
      node,
      {Namespace, :tokens},
      {:ok,
       [
         %{
           id: "tok-1",
           principal: "ci",
           namespace: "default",
           role: :app,
           label: nil,
           status: :active
         }
       ]}
    )

    FakeController.set(
      node,
      {PluginManager, :enabled},
      {:ok,
       [
         %{
           name: "out_1",
           provider: "relay_stdout",
           single: false,
           relays: ["relay_a"],
           controllers: [],
           hooks: [],
           lagging: []
         }
       ]}
    )

    FakeController.set(
      node,
      {Schedule, :list},
      {:ok,
       [
         %{
           name: "nightly",
           cron: "0 3 * * *",
           timezone: "Etc/UTC",
           namespace: "default",
           factory_id: "echo_steps",
           armed: true,
           last_fire: nil,
           next_fire: nil
         }
       ]}
    )

    :ok
  end

  defp grant(node, operations) do
    FakeController.set(
      node,
      {Namespace, :whoami},
      {:ok, %{principal: "p@acme", namespace: "default", role: :viewer, operations: operations}}
    )
  end

  defp screens(conn) do
    {:ok, relay, _html} = live(conn, ~p"/namespaces/default/relays/relay_a")
    {:ok, state, _html} = live(conn, ~p"/namespaces/default/relays/relay_a/state")
    render_click(state, "select_cell", %{"cell" => "relay_a/orders/k1"})
    {:ok, namespace, _html} = live(conn, ~p"/namespaces/default")
    open_section(namespace, "role-bindings")
    open_section(namespace, "tokens")
    {:ok, plugins, _html} = live(conn, ~p"/plugins")
    {:ok, schedules, _html} = live(conn, ~p"/schedules")
    {:ok, audit, _html} = live(conn, ~p"/audit")

    Enum.map_join([relay, state, namespace, plugins, schedules, audit], &render/1)
  end

  # The testid of each control, with the role that may use it.
  @controls %{
    "stop-relay-btn" => :ops,
    "talk-open-btn" => :ops,
    "attach-plugin-btn" => :ops,
    "replay-open" => :ops,
    "rotate-relay_a/orders/k1" => :ops,
    "delete-relay_a/orders/k1" => :admin,
    "retention-form" => :admin,
    "start-relay-btn" => :ops,
    "bind-role-btn" => :admin,
    "unbind-role-alice-ops" => :admin,
    "issue-token-btn" => :admin,
    "revoke-token-tok-1" => :admin,
    "enable-plugin-btn" => :ops,
    "plugin-bind-out_1" => :ops,
    "plugin-update-out_1" => :ops,
    "plugin-disable-out_1" => :ops,
    "plugin-unbind-out_1-relay_a" => :ops,
    "schedule-run-nightly" => :ops,
    "schedule-remove-nightly" => :ops,
    "schedule-new-btn" => :ops,
    "audit-rotate-btn" => :ops
  }

  defp rendered?(html, testid), do: html =~ ~s(data-testid="#{testid}")

  test "a viewer gets none of the controls and every read-only panel", %{conn: conn, node: node} do
    grant(node, @viewer)
    html = screens(conn)

    for {testid, _role} <- @controls, do: refute(rendered?(html, testid), "#{testid} rendered")

    for panel <-
          ~w(diagnose-btn api-panel time-travel role-bindings tokens-panel installed-catalog),
        do: assert(rendered?(html, panel), "#{panel} missing")
  end

  test "ops gets rotation and replay, not delete, retention, tokens or bindings", %{
    conn: conn,
    node: node
  } do
    grant(node, @ops)
    html = screens(conn)

    for {testid, role} <- @controls do
      if role == :ops,
        do: assert(rendered?(html, testid), "#{testid} missing"),
        else: refute(rendered?(html, testid), "#{testid} rendered")
    end
  end

  test "an answer without operations renders every control", %{conn: conn} do
    html = screens(conn)

    for {testid, _role} <- @controls, do: assert(rendered?(html, testid), "#{testid} missing")
  end

  test "whoami is read once for a token across refresh ticks", %{conn: conn, node: node} do
    grant(node, @ops)
    {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays/relay_a")

    for _tick <- 1..3 do
      send(view.pid, :refresh)
      render(view)
    end

    assert length(FakeController.calls(node, {Namespace, :whoami})) == 1
  end

  test "a rendered control's refusal is still shown", %{conn: conn, node: node} do
    grant(node, @ops)

    FakeController.set(
      node,
      {Relay, :stop},
      FakeController.error("authz.role_insufficient", "ops may not stop relays here")
    )

    {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays/relay_a")
    view |> element(~s([data-testid="stop-relay-btn"])) |> render_click()
    html = view |> element(~s([data-testid="stop-confirm-btn"])) |> render_click()

    assert html =~ "ops may not stop relays here"
  end
end
