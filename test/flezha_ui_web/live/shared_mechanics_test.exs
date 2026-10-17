defmodule FlezhaUiWeb.SharedMechanicsTest do
  @moduledoc """
  Behaviour several screens get from one shared component or one shared
  pattern, asserted once over a table of the screens that carry it.

  Each table row is one screen's use of the mechanic and becomes its own test,
  named after the screen, so a screen that breaks it fails by name. A screen
  that gains the mechanic takes one new row.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.AuditLog
  alias Flezha.Service.Controller
  alias Flezha.Service.Dlq
  alias Flezha.Service.Fleet
  alias Flezha.Service.Namespace
  alias Flezha.Service.Observability
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay
  alias Flezha.Service.Schedule
  alias Flezha.Service.Steps

  defp click(view, testid), do: view |> element(~s([data-testid="#{testid}"])) |> render_click()

  # ---- What each row stands on ----

  @ops %{principal: "ops@default", namespace: "default", role: :ops}

  defp arrange(:none, _node, _user), do: :ok

  defp arrange(:fleet, node, _user), do: FakeController.set_fleet(node, rows: %{"default" => []})

  defp arrange(:plugins, node, _user) do
    FakeController.set(
      node,
      {Relay, :list_namespaces},
      {:ok, [%{namespace: "default", running: true}]}
    )

    plugin = %{
      name: "out_1",
      provider: "std_out",
      provider_id: "relay_stdout",
      single: false,
      relays: ["relay_a"],
      controllers: [],
      hooks: ["on_output"],
      lagging: []
    }

    FakeController.set(node, {PluginManager, :enabled}, {:ok, [plugin]})
  end

  defp arrange(:relay, node, _user) do
    FakeController.set(
      node,
      {Relay, :overwatch_state},
      {:ok, %{factory_id: "store_input", extensions: FakeController.hook_table("plug_1")}}
    )
  end

  defp arrange(:relays, node, _user) do
    FakeController.set_fleet(node, rows: %{"default" => [FakeController.relay_row("relay_a")]})
    FakeController.set(node, {Fleet, :runners}, {:ok, [%{id: "runner-a", pid: nil}]})
    FakeController.set(node, {Relay, :overwatch_state}, {:ok, %{factory_id: "store_input"}})
  end

  defp arrange(:namespaces, node, _user) do
    FakeController.set(
      node,
      {Relay, :list_namespaces},
      {:ok, [%{namespace: "doomed", running: false}]}
    )

    FakeController.set(node, {Namespace, :list}, {:ok, [namespace_record("doomed")]})
  end

  defp arrange(:access, node, _user) do
    FakeController.set(
      node,
      {Relay, :list_namespaces},
      {:ok, [%{namespace: "default", running: true}]}
    )

    FakeController.set(node, {Namespace, :list}, {:ok, []})
    FakeController.set(node, {Namespace, :get}, {:ok, namespace_record("default")})

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
           label: "deploys",
           status: :active
         }
       ]}
    )
  end

  defp arrange(:many_namespaces, node, _user) do
    names = Enum.map(1..25, &"ns_#{String.pad_leading("#{&1}", 2, "0")}")

    FakeController.set(
      node,
      {Relay, :list_namespaces},
      {:ok, Enum.map(names, &%{namespace: &1, running: true})}
    )
  end

  defp arrange(:many_relays, node, _user) do
    rows =
      Enum.map(1..25, &FakeController.relay_row("relay_#{String.pad_leading("#{&1}", 2, "0")}"))

    FakeController.set_fleet(node, rows: %{"default" => rows})
  end

  defp arrange(:many_tokens, node, user) do
    arrange(:access, node, user)

    tokens =
      for i <- 1..25 do
        %{
          id: "tok-#{i}",
          principal: "ci",
          namespace: "default",
          role: :app,
          label: "t#{i}",
          status: :active
        }
      end

    FakeController.set(node, {Namespace, :tokens}, {:ok, tokens})
  end

  defp arrange(:many_bindings, node, user) do
    arrange(:access, node, user)

    bindings =
      for i <- 1..25, do: %{principal: "user_#{i}", namespace: "default", roles: [:viewer]}

    FakeController.set(node, {Namespace, :roles}, {:ok, bindings})
  end

  defp arrange(:dlq, node, _user) do
    entry = %{
      "relay_class" => "orders",
      "tasklet_id" => "charge",
      "id" => "17",
      "cell_key" => "cust-9",
      "channel" => "payments",
      "generation" => 2,
      "status" => "parked",
      "ts_ms" => System.system_time(:millisecond) - 30_000,
      "error" => "upstream refused"
    }

    FakeController.set(node, {Dlq, :list}, {:ok, [entry]})
  end

  defp arrange(:schedules, node, _user) do
    entry = %{
      name: "nightly",
      cron: "0 3 * * *",
      timezone: "Etc/UTC",
      namespace: "default",
      factory_id: "echo_steps",
      init_values: %{},
      node: :"flezha@hub-1",
      last_fire: nil,
      next_fire: ~U[2031-06-01 03:00:00Z]
    }

    FakeController.set(node, {Schedule, :list}, {:ok, [entry]})
  end

  defp arrange(:cells, node, _user) do
    cell = %{
      relay_class: "relay_a",
      tasklet_id: "orders",
      cell_key: "k1",
      wal_seq: 120,
      snapshot_seq: 100,
      wal_bytes: 4096,
      flush_latency_ms_p99: 3,
      fsync_durability_lag_ms: 0,
      dedup_drops_total: 0
    }

    FakeController.set(node, {Steps, :cells}, {:ok, %{relay_class: "relay_a", cells: [cell]}})
    FakeController.set(node, {Relay, :overwatch_state}, {:ok, %{builder: %{run: :flow}}})
  end

  defp arrange(:journal, node, _user) do
    FakeController.set(
      node,
      {Relay, :relay_rows},
      {:ok, [FakeController.relay_row("relay_steps", %{factory: "chat_loop_steps"})]}
    )

    FakeController.set(
      node,
      {Relay, :overwatch_state},
      {:ok,
       %{factory_id: "chat_loop_steps", builder: %{run: :steps, opts: []}, durable_steps: true}}
    )

    FakeController.set(node, {Steps, :committed_iterations}, {:ok, [2]})
  end

  defp arrange(:partition_group, node, _user) do
    members =
      for index <- [0, 1] do
        FakeController.relay_row("orders#p#{index}", %{
          factory: "chat_loop_steps",
          partition: %{
            group: "orders",
            index: index,
            count: 2,
            range: {index * 128, index * 128 + 127}
          }
        })
      end

    FakeController.set_fleet(node, rows: %{"default" => members})

    FakeController.set(
      node,
      {Relay, :partition_groups},
      {:ok, [%{group: "orders", declared: 2, members: members, coverage: :ok}]}
    )
  end

  defp arrange(:runners, node, user) do
    enforce_operations(node, user, @ops)

    grant_operations(node, @ops, [
      "Fleet.runners",
      "Fleet.drop_runner",
      "Fleet.readmit_runner"
    ])

    FakeController.set(
      node,
      {Relay, :list_namespaces},
      {:ok, [%{namespace: "default", running: true}]}
    )

    FakeController.set(node, {Fleet, :runners}, {:ok, [%{id: "runner-a", pid: 4242}]})

    FakeController.set(
      node,
      {Fleet, :dropped_runners},
      {:ok,
       [
         %{
           stable_id: "stable-b",
           incarnation: "inc-1",
           pid: 5151,
           node: :"flezha@node-a",
           dropped_at: 1_760_000_000,
           dropped_by: "ops@default"
         }
       ]}
    )
  end

  defp namespace_record(name) do
    %{
      name: name,
      quotas: %{
        max_relays: 100,
        max_cells_per_relay: 1_024,
        max_mailbox_bytes_total: 268_435_456,
        max_message_rate_per_second: 100_000,
        max_state_bytes: 107_374_182_400,
        max_runners: 32
      },
      created_at: 1_760_000_000,
      created_by_principal: "root"
    }
  end

  describe "cancelling a confirmation" do
    # `before` are the controls clicked to reach the opening control, such as
    # a folded section; `says` is a phrase the dialog must state; `kept` is the
    # target, which must still be shown after the cancel.
    @dialogs [
      %{
        screen: "plugins",
        dialog: "disable",
        route: "/plugins",
        arrange: :plugins,
        open: "plugin-disable-out_1",
        modal: "plugin-disable-modal",
        cancel: "plugin-disable-cancel",
        call: {PluginManager, :disable},
        kept: "plugin-row-out_1"
      },
      %{
        screen: "plugins",
        dialog: "unbind",
        route: "/plugins",
        arrange: :plugins,
        open: "plugin-unbind-out_1-relay_a",
        modal: "plugin-unbind-modal",
        says: "stays enabled",
        cancel: "plugin-unbind-cancel",
        call: {PluginManager, :unbind},
        kept: "plugin-unbind-out_1-relay_a"
      },
      %{
        screen: "relay detail",
        dialog: "stop",
        route: "/namespaces/default/relays/relay_a",
        arrange: :relay,
        open: "stop-relay-btn",
        modal: "stop-confirm-modal",
        says: "Stop relay?",
        cancel: "stop-cancel-btn",
        call: {Relay, :stop},
        kept: "stop-relay-btn"
      },
      %{
        screen: "relay detail",
        dialog: "unbind",
        route: "/namespaces/default/relays/relay_a",
        arrange: :relay,
        before: ["section-toggle-plugins"],
        open: "unbind-btn-plug_1",
        modal: "unbind-confirm-modal",
        cancel: "unbind-cancel-btn",
        call: {PluginManager, :unbind},
        kept: "unbind-btn-plug_1"
      },
      %{
        screen: "namespace home",
        dialog: "relay stop",
        route: "/namespaces/default?inspect=relay:relay_a",
        arrange: :relays,
        open: "inspector-stop",
        modal: "stop-confirm-modal",
        cancel: "stop-cancel-btn",
        call: {Relay, :stop},
        kept: "inspector-relay"
      },
      %{
        screen: "relays index",
        dialog: "relay stop",
        route: "/relays",
        arrange: :relays,
        open: "stop-relay-relay_a",
        modal: "stop-confirm-modal",
        cancel: "stop-cancel-btn",
        call: {Relay, :stop},
        kept: "relay-index-row-relay_a"
      },
      %{
        screen: "namespaces",
        dialog: "delete",
        route: "/namespaces",
        arrange: :namespaces,
        open: "namespace-delete-doomed",
        modal: "delete-namespace-modal",
        cancel: "delete-namespace-cancel",
        call: {Namespace, :delete},
        kept: "namespace-row-doomed"
      },
      %{
        screen: "namespace home",
        dialog: "role unbind",
        route: "/namespaces/default",
        arrange: :access,
        before: ["section-toggle-access"],
        open: "unbind-binding-alice",
        modal: "unbind-role-modal",
        cancel: "unbind-role-cancel",
        call: {Namespace, :unbind_role},
        kept: "role-binding-alice"
      },
      %{
        screen: "namespace home",
        dialog: "role bind",
        route: "/namespaces/default",
        arrange: :access,
        before: ["section-toggle-access"],
        open: "bind-role-btn",
        modal: "bind-role-modal",
        cancel: "bind-role-cancel",
        call: {Namespace, :bind_role},
        kept: "role-binding-alice"
      },
      %{
        screen: "namespace home",
        dialog: "token revocation",
        route: "/namespaces/default",
        arrange: :access,
        before: ["section-toggle-access"],
        open: "revoke-token-tok-1",
        modal: "revoke-token-modal",
        cancel: "revoke-token-cancel",
        call: {Namespace, :revoke_token},
        kept: "revoke-token-tok-1"
      },
      %{
        screen: "namespace home",
        dialog: "rescale",
        route: "/namespaces/default",
        arrange: :partition_group,
        before: ["section-toggle-partition-groups"],
        open: "rescale-orders",
        modal: "rescale-modal",
        cancel: "rescale-cancel-btn",
        call: {Steps, :rescale},
        kept: "rescale-orders"
      },
      %{
        screen: "dead-letter queue",
        dialog: "drop",
        route: "/dlq",
        arrange: :dlq,
        open: "dlq-drop-orders/charge/17",
        modal: "dlq-confirm-modal",
        cancel: "dlq-confirm-cancel",
        call: {Dlq, :drop},
        kept: "dlq-row-orders/charge/17"
      },
      %{
        screen: "dead-letter queue",
        dialog: "replay",
        route: "/dlq",
        arrange: :dlq,
        open: "dlq-replay-orders/charge/17",
        modal: "dlq-confirm-modal",
        cancel: "dlq-confirm-cancel",
        call: {Dlq, :replay},
        kept: "dlq-row-orders/charge/17"
      },
      %{
        screen: "schedules",
        dialog: "remove",
        route: "/schedules",
        arrange: :schedules,
        open: "schedule-remove-nightly",
        modal: "schedule-remove-modal",
        cancel: "schedule-remove-cancel",
        call: {Schedule, :remove},
        kept: "schedule-row-nightly"
      },
      %{
        screen: "schedules",
        dialog: "run now",
        route: "/schedules",
        arrange: :schedules,
        open: "schedule-run-nightly",
        modal: "schedule-run-modal",
        cancel: "schedule-run-cancel",
        call: {Schedule, :run},
        kept: "schedule-row-nightly"
      },
      %{
        screen: "relay state",
        dialog: "rotation",
        route: "/namespaces/default/relays/relay_a/state",
        arrange: :cells,
        open: "rotate-relay_a/orders/k1",
        modal: "state-confirm-modal",
        cancel: "state-confirm-cancel",
        call: {Steps, :rotate},
        kept: "cell-relay_a/orders/k1"
      },
      %{
        screen: "relay state",
        dialog: "cell delete",
        route: "/namespaces/default/relays/relay_a/state",
        arrange: :cells,
        open: "delete-relay_a/orders/k1",
        modal: "state-confirm-modal",
        cancel: "state-confirm-cancel",
        call: {Steps, :delete},
        kept: "cell-relay_a/orders/k1"
      },
      %{
        screen: "relay state",
        dialog: "replay",
        route: "/namespaces/default/relays/relay_a/state",
        arrange: :cells,
        before: ["select-relay_a/orders/k1"],
        open: "replay-open",
        modal: "state-confirm-modal",
        cancel: "state-confirm-cancel",
        call: {Relay, :replay},
        kept: "cell-relay_a/orders/k1"
      },
      %{
        screen: "relay state",
        dialog: "rewind",
        route: "/namespaces/default/relays/relay_steps/state",
        arrange: :journal,
        open: "open-rewind-btn",
        modal: "rewind-modal",
        cancel: "rewind-cancel-btn",
        call: {Steps, :rewind},
        kept: "open-rewind-btn"
      },
      %{
        screen: "controller",
        dialog: "stop",
        route: "/controller",
        arrange: :none,
        open: "stop-controller-btn",
        modal: "stop-controller-modal",
        cancel: "stop-cancel",
        call: {Controller, :stop},
        kept: "stop-controller-btn"
      },
      %{
        screen: "cluster",
        dialog: "runner drop",
        route: "/cluster",
        arrange: :runners,
        open: "drop-runner-runner-a",
        modal: "drop-runner-modal",
        cancel: "drop-runner-cancel",
        call: {Fleet, :drop_runner},
        kept: "runner-runner-a"
      },
      %{
        screen: "cluster",
        dialog: "runner readmit",
        route: "/cluster",
        arrange: :runners,
        open: "readmit-runner-stable-b",
        modal: "readmit-runner-modal",
        cancel: "readmit-runner-cancel",
        call: {Fleet, :readmit_runner},
        kept: "runner-mark-stable-b"
      },
      %{
        screen: "namespace home",
        dialog: "runner drop",
        route: "/namespaces/default",
        arrange: :runners,
        before: ["section-toggle-runners"],
        open: "drop-runner-runner-a",
        modal: "drop-runner-modal",
        cancel: "drop-runner-cancel",
        call: {Fleet, :drop_runner},
        kept: "runner-runner-a"
      },
      %{
        screen: "namespace home",
        dialog: "runner readmit",
        route: "/namespaces/default",
        arrange: :runners,
        before: ["section-toggle-runners"],
        open: "readmit-runner-stable-b",
        modal: "readmit-runner-modal",
        cancel: "readmit-runner-cancel",
        call: {Fleet, :readmit_runner},
        kept: "runner-mark-stable-b"
      }
    ]

    for row <- @dialogs do
      @row row

      test "#{row.screen}: cancelling the #{row.dialog} confirmation calls nothing", %{
        conn: conn,
        node: node,
        user: user
      } do
        row = @row
        arrange(row.arrange, node, user)
        {:ok, view, _html} = live(conn, row.route)
        Enum.each(row[:before] || [], &click(view, &1))

        html = click(view, row.open)
        assert has_element?(view, ~s([data-testid="#{row.modal}"]))
        if says = row[:says], do: assert(html =~ says)

        click(view, row.cancel)

        refute has_element?(view, ~s([data-testid="#{row.modal}"]))
        assert FakeController.calls(node, row.call) == []
        assert has_element?(view, ~s([data-testid="#{row.kept}"]))
      end
    end
  end

  describe "a refused primary read" do
    # The screen's main read refused: it states the code and the controller's
    # message instead of crashing or rendering as empty. `kept` are panels
    # that must still render beside the refusal.
    @reads [
      %{screen: "namespaces", route: "/namespaces", read: {Relay, :list_namespaces}},
      %{screen: "relays index", route: "/relays", read: {Relay, :list_namespaces}},
      %{screen: "cluster", route: "/cluster", read: {Relay, :list_namespaces}},
      %{screen: "dead-letter queue", route: "/dlq", read: {Dlq, :list}},
      %{screen: "schedules", route: "/schedules", read: {Schedule, :list}},
      %{screen: "observability", route: "/observability", read: {Observability, :list_sources}},
      %{
        screen: "relay detail",
        route: "/namespaces/default/relays/relay_a",
        read: {Relay, :overwatch_state}
      },
      %{
        screen: "relay state",
        route: "/namespaces/default/relays/relay_a/state",
        read: {Steps, :cells}
      },
      %{
        screen: "controller",
        route: "/controller",
        read: {Controller, :status},
        kept: ["shutdown-unavailable", "boot-panel"]
      }
    ]

    for row <- @reads do
      @row row

      test "#{row.screen}: a refused read states its code and message", %{
        conn: conn,
        node: node
      } do
        row = @row
        message = "refused for the #{row.screen} screen"

        FakeController.set(
          node,
          row.read,
          FakeController.error("authz.role_insufficient", message)
        )

        {:ok, view, html} = live(conn, row.route)

        stated = text_of(html, ~s([data-testid="runtime-error"]))
        assert stated =~ "authz.role_insufficient"
        assert stated =~ message
        for kept <- row[:kept] || [], do: assert(has_element?(view, ~s([data-testid="#{kept}"])))
      end
    end
  end

  describe "an empty screen" do
    # What nothing to show reads as on each screen: `in` is where it is said.
    @empties [
      %{
        screen: "namespaces",
        route: "/namespaces",
        in: ~s([data-testid="namespaces-empty"]),
        says: "None is reachable with this console"
      },
      %{
        screen: "relays index",
        route: "/relays",
        arrange: :fleet,
        in: ~s([data-testid="relays-empty"]),
        says: "None is running in any namespace you can reach."
      },
      %{
        screen: "namespace home",
        route: "/namespaces/default",
        arrange: :fleet,
        in: ~s([data-testid="topology-empty"]),
        says: "Nothing runs in default yet"
      },
      %{
        screen: "namespace home's finished relays",
        route: "/namespaces/default",
        arrange: :fleet,
        before: ["section-toggle-finished-relays"],
        in: ~s([data-testid="section-body-finished-relays"]),
        says: "None has finished"
      },
      %{
        screen: "cluster",
        route: "/cluster",
        in: ~s([data-testid="cluster-namespaces-empty"]),
        says: "No namespace is running."
      },
      %{
        screen: "cluster's runners",
        route: "/cluster",
        arrange: :fleet,
        in: ~s([data-testid="runners-empty-default"]),
        says: "None has connected."
      },
      %{
        screen: "plugins",
        route: "/plugins",
        in: ~s([data-testid="plugins-empty"]),
        says: "None is enabled."
      },
      %{
        screen: "schedules",
        route: "/schedules",
        in: ~s([data-testid="schedule-empty"]),
        says: "None has been created."
      },
      %{
        screen: "dead-letter queue",
        route: "/dlq",
        in: ~s([data-testid="dlq-empty"]),
        says: "The queue is empty."
      },
      %{
        screen: "relay state",
        route: "/namespaces/default/relays/relay_a/state",
        in: ~s([data-testid="state-empty"]),
        says: "This relay has none persisted yet."
      }
    ]

    for row <- @empties do
      @row row

      test "#{row.screen}: nothing to show is said, not left blank", %{
        conn: conn,
        node: node,
        user: user
      } do
        row = @row
        arrange(row[:arrange] || :none, node, user)

        {:ok, view, html} = live(conn, row.route)

        html =
          Enum.reduce(row[:before] || [], html, fn testid, _html -> click(view, testid) end)

        assert text_of(html, row.in) =~ row.says
      end
    end
  end

  describe "closing a tail" do
    @tails [
      %{
        screen: "audit log",
        route: "/audit",
        tail: {AuditLog, :tail},
        start: "audit-tail-toggle",
        stop: "audit-tail-toggle"
      },
      %{
        screen: "observability",
        route: "/observability",
        tail: {Observability, :tail},
        start: "tail-flezha_health",
        stop: "stop-tail"
      }
    ]

    setup %{node: node} do
      FakeController.set(node, {AuditLog, :list_files}, {:ok, []})

      FakeController.set(
        node,
        {Observability, :list_sources},
        {:ok, [%{name: :flezha_health, status: :active}]}
      )
    end

    defp tailing(conn, node, row) do
      {:ok, view, _html} = live(conn, row.route)
      click(view, row.start)
      assert PeerNode.eventually(fn -> FakeController.streams(node, row.tail) != [] end)
      view
    end

    for row <- @tails do
      @row row

      test "#{row.screen}: stopping the tail ends the controller's stream", %{
        conn: conn,
        node: node
      } do
        view = tailing(conn, node, @row)

        click(view, @row.stop)

        assert PeerNode.eventually(fn -> FakeController.streams(node, @row.tail) == [] end)
      end

      test "#{row.screen}: leaving the screen ends the controller's stream", %{
        conn: conn,
        node: node
      } do
        view = tailing(conn, node, @row)

        # The screen dies without saying goodbye; its feed goes with it.
        Process.flag(:trap_exit, true)
        Process.exit(view.pid, :kill)

        assert PeerNode.eventually(fn -> FakeController.streams(node, @row.tail) == [] end)
      end
    end
  end

  describe "a long listing" do
    # Each listing holds 25 rows: `rows` counts what it shows, `more` is its
    # control, and `before` opens the folded section it sits in.
    @listings [
      %{
        screen: "namespaces",
        route: "/namespaces",
        arrange: :many_namespaces,
        rows: ~s(li[data-testid^="namespace-row-"]),
        more: "namespaces-more"
      },
      %{
        screen: "relays index",
        route: "/relays",
        arrange: :many_relays,
        rows: ~s(tr[data-testid^="relay-index-row-"]),
        more: "relay-rows-more"
      },
      %{
        screen: "namespace home's tokens",
        route: "/namespaces/default",
        arrange: :many_tokens,
        before: ["section-toggle-access"],
        rows: ~s(tr[data-testid^="token-tok"]),
        more: "tokens-grid-more"
      },
      %{
        screen: "namespace home's role bindings",
        route: "/namespaces/default",
        arrange: :many_bindings,
        before: ["section-toggle-access"],
        rows: ~s(tr[data-testid^="role-binding-"]),
        more: "role-bindings-grid-more"
      }
    ]

    defp shown(html, selector),
      do: html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()

    for row <- @listings do
      @row row

      test "#{row.screen}: shows a page, grows by one, and keeps it through a tick", %{
        conn: conn,
        node: node,
        user: user
      } do
        row = @row
        arrange(row.arrange, node, user)

        {:ok, view, html} = live(conn, row.route)
        html = Enum.reduce(row[:before] || [], html, fn testid, _html -> click(view, testid) end)

        assert shown(html, row.rows) == 20
        assert text_of(html, ~s([data-testid="#{row.more}"])) == "Show 5 more · 20 of 25"

        html =
          view
          |> element(~s([data-testid="#{row.more}"][phx-click="grid_more"]))
          |> render_click()

        assert shown(html, row.rows) == 25
        refute has_element?(view, ~s([data-testid="#{row.more}"]))

        send(view.pid, :refresh)
        assert view |> render() |> shown(row.rows) == 25
      end
    end
  end

  describe "a relay's verdicts on each screen that lists it" do
    # `reads` is the element that states one relay's facts on that screen.
    @screens [
      %{screen: "relays index", route: "/relays", reads: :row},
      %{screen: "relay detail", route: "/namespaces/default/relays/:id", reads: :header}
    ]

    # Every relay is listed in `default`, and the detail screen's overwatch
    # read answers each one with its own builder.
    defp list_relays(node, rows, runs \\ %{}) do
      FakeController.set_fleet(node, rows: %{"default" => rows}, runs: runs)

      overwatch =
        Map.new(rows, fn row ->
          builder = if run = runs[row.id], do: %{run: run, opts: []}, else: %{opts: []}
          {row.id, {:ok, %{factory_id: "store_input", builder: builder}}}
        end)

      FakeController.set(node, {Relay, :overwatch_state}, {:per_arg, 1, overwatch, {:ok, %{}}})
    end

    defp facts_of(conn, row, id) do
      {:ok, _view, html} = live(conn, String.replace(row.route, ":id", id))
      read(html, row.reads, id)
    end

    defp read(html, :row, id), do: text_of(html, ~s([data-testid="relay-index-row-#{id}"]))
    defp read(html, :header, _id), do: text_of(html, ~s([data-testid="page-header"]))

    for row <- @screens do
      @row row

      test "#{row.screen}: every health verdict reads in its own words", %{
        conn: conn,
        node: node
      } do
        # Ids that name no verdict, so only the screen's words can match.
        verdicts = Enum.with_index([nil | FlezhaUiWeb.Words.health_verdicts()])

        list_relays(
          node,
          Enum.map(verdicts, fn {health, i} ->
            FakeController.relay_row("relay_#{i}", %{health: health})
          end)
        )

        for {health, i} <- verdicts do
          words = :health |> FlezhaUiWeb.Words.text(health) |> String.downcase()
          facts = conn |> facts_of(@row, "relay_#{i}") |> String.downcase()

          assert facts =~ words, "#{inspect(health)} does not read #{words}: #{facts}"
          if health != :healthy, do: refute(facts =~ "healthy")
        end
      end

      test "#{row.screen}: a relay with no live node is named as unplaced", %{
        conn: conn,
        node: node
      } do
        list_relays(node, [
          FakeController.relay_row("relay_a", %{node: nil}),
          FakeController.relay_row("relay_b", %{node: :"flezha@node-b"})
        ])

        assert conn |> facts_of(@row, "relay_a") |> String.downcase() =~ "unplaced"
        refute conn |> facts_of(@row, "relay_b") |> String.downcase() =~ "unplaced"
      end

      test "#{row.screen}: each relay's run is stated as its builder holds it", %{
        conn: conn,
        node: node
      } do
        list_relays(
          node,
          [FakeController.relay_row("relay_a"), FakeController.relay_row("relay_b")],
          %{"relay_a" => :steps}
        )

        steps = facts_of(conn, @row, "relay_a")
        flow = facts_of(conn, @row, "relay_b")

        assert steps =~ ~r/\bsteps\b/
        refute steps =~ ~r/\bflow\b/
        assert flow =~ ~r/\bflow\b/
        refute flow =~ ~r/\bsteps\b/
      end
    end
  end
end
