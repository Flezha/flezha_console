defmodule FlezhaConsoleWeb.RoleGatingTest do
  @moduledoc """
  Controls follow the operations the bound role is granted, as core's
  `Namespace.whoami/1` lists them: a control whose operation is not granted is
  not rendered, the read-only panels still are, an answer with no list renders
  everything, and the list is read once per token.

  The lists are the ones core's `Admin.catalogue/1` answers for each role.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Logs
  alias Flezha.Service.Namespace
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay
  alias Flezha.Service.Schedule
  alias Flezha.Service.Steps

  @viewer ~w(Logs.files Logs.read Logs.stats Logs.tail
             Controller.status Controller.boot_status Controller.cluster_status
             Fleet.factories Fleet.installed_plugins Fleet.provider Fleet.providers Fleet.runners
             Fleet.runners_for_factory Namespace.get Namespace.list Namespace.quota
             Namespace.quota_kinds Namespace.roles Namespace.tokens Namespace.whoami
             PluginManager.enabled Relay.api Relay.cell_state Relay.diagnose Relay.info Relay.list
             Relay.list_namespaces Relay.overwatch_state Relay.partition_groups
             Relay.registry Relay.relay_plugins Relay.relay_rows Schedule.list Steps.cells
             Steps.completed_retention_hours Steps.time_travel)

  @ops @viewer ++
         ~w(Logs.rotate Dlq.drop Dlq.replay PluginManager.bind PluginManager.disable
            PluginManager.enable PluginManager.unbind PluginManager.update Relay.call
            Relay.call_channel Relay.listen Relay.replay Relay.send Relay.start Relay.stop
            Schedule.add Schedule.remove Schedule.run Steps.inbox Steps.outbox Steps.rescale
            Steps.rewind Steps.rotate)

  @identity %{principal: "p@acme", namespace: "default", role: :viewer}

  setup %{node: node, user: user} do
    enforce_operations(node, user, @identity)

    # One controller of a fixed name, so its Rotate control has a known testid.
    FakeController.set(
      node,
      {Logs, :stats},
      {:ok, %{controllers: [FakeController.log_stats_row(:"flezha@node-a")], unreachable: []}}
    )

    FakeController.set(
      node,
      {Relay, :overwatch_state},
      {:ok, %{builder: %{run: :flow}, extensions: FakeController.hook_table("plug_1")}}
    )

    FakeController.set(
      node,
      {Relay, :list},
      FakeController.rows([FakeController.relay_row("relay_a")])
    )

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
      FakeController.rows([
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
      ])
    )

    :ok
  end

  defp grant(node, operations), do: grant_operations(node, @identity, operations)

  defp screens(conn) do
    {:ok, relay, _html} = live(conn, ~p"/namespaces/default/relays/relay_a")
    open_section(relay, "plugins")
    {:ok, state, _html} = live(conn, ~p"/namespaces/default/relays/relay_a/state")
    state |> element(~s([data-testid="select-relay_a/orders/k1"])) |> render_click()
    {:ok, namespace, _html} = live(conn, ~p"/namespaces/default")
    open_section(namespace, "access")
    {:ok, plugins, _html} = live(conn, ~p"/plugins")
    {:ok, schedules, _html} = live(conn, ~p"/schedules")
    {logs, _html} = live_loaded(conn, ~p"/logs/audit")

    Enum.map_join([relay, state, namespace, plugins, schedules, logs], &render/1)
  end

  # The testid of each control, with the role that may use it.
  @controls %{
    "stop-relay-btn" => :ops,
    "talk-open-btn" => :ops,
    "calls-panel" => :ops,
    "attach-plugin-btn" => :ops,
    "unbind-btn-plug_1" => :ops,
    "replay-open" => :ops,
    "rotate-relay_a/orders/k1" => :ops,
    "delete-relay_a/orders/k1" => :admin,
    "retention-form" => :admin,
    "start-relay-btn" => :ops,
    "enable-plugin-btn" => :ops,
    "plugin-bind-out_1" => :ops,
    "plugin-update-out_1" => :ops,
    "plugin-disable-out_1" => :ops,
    "plugin-unbind-out_1-relay_a" => :ops,
    "schedule-run-nightly" => :ops,
    "schedule-remove-nightly" => :ops,
    "schedule-new-btn" => :ops,
    "logs-rotate-flezha@node-a" => :ops
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

  test "ops gets rotation and replay, not delete or retention", %{
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

  test "a viewer's forged calls toggle holds no listen", %{conn: conn, node: node} do
    grant(node, @viewer)
    {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays/relay_a")

    render_click(view, "section_toggle", %{"key" => "calls"})
    render_click(view, "calls_reopen", %{})

    assert FakeController.calls(node, {Relay, :listen}) == []
  end

  test "a viewer's forged stop reaches the controller as the viewer and shows its refusal", %{
    user: user,
    conn: conn,
    node: node
  } do
    grant(node, @viewer)

    FakeController.set(
      node,
      {Relay, :stop},
      FakeController.error("authz.role_insufficient", "viewer may not stop relays")
    )

    {:ok, view, html} = live(conn, ~p"/namespaces/default/relays/relay_a")
    refute rendered?(html, "stop-relay-btn")

    html = render_click(view, "stop_relay", %{})

    assert [["default", "relay_a", context]] = FakeController.calls(node, {Relay, :stop})
    # The controller judges the call by the principal the viewer's token proves.
    assert context.token == FlezhaConsole.Accounts.user_flezha_token(user)
    assert html =~ "viewer may not stop relays"
    assert html =~ "authz.role_insufficient"
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
