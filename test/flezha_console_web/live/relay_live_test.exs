defmodule FlezhaConsoleWeb.RelayLiveTest do
  @moduledoc """
  The relay detail screen.

  The browser suite drives attach and detach against a real controller, which
  is the only place the provider forms can be trusted. Covered here: the
  overwatch panel's shape, the cell-state reader, the payload tap, the attach
  form's call, and the refusals — a controller that will not stop the relay,
  will not report its state, or has diverged from this UI's API.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.Logs
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay

  @url "/namespaces/default/relays/relay_a"

  defp overwatch(node, state) do
    FakeController.set(node, {Relay, :overwatch_state}, {:ok, state})
  end

  defp registry_row(node, overrides) do
    row = FakeController.relay_row("relay_a", overrides)

    FakeController.set(node, {Relay, :list}, FakeController.rows([row]))
  end

  describe "registry facts" do
    test "health and node come from the namespace's rows", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{health: :degraded, node: :"flezha@node-b"})

      {:ok, _view, html} = live(conn, @url)

      assert text_of(html, ~s([data-testid="relay-health"])) =~ "It is degraded"
      assert html =~ ~s(data-testid="relay-node")
      assert html =~ "flezha@node-b"
    end

    test "a relay hosted on another controller reads as that controller judged it, every section with it",
         %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{health: :healthy, node: :"flezha@node-b"})
      FakeController.set(node, {Relay, :graph}, FakeController.one_tasklet_graph("relay_a"))

      {:ok, _view, html} = live(conn, @url)

      assert text_of(html, ~s([data-testid="relay-health"])) =~ "It is healthy"
      assert html =~ "flezha@node-b"
      refute html =~ ~s(data-testid="partial-answer")

      for section <- ~w(topology-graph diagnose-panel calls-panel api-panel bindings-panel),
          do: assert(html =~ ~s(data-testid="#{section}"), section)
    end

    test "a hosting controller that did not answer is named, and its relay reads unknown", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input"})
      row = FakeController.relay_row("relay_a", %{health: :unknown, node: :"flezha@node-b"})

      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows([row], ["flezha@node-b"])
      )

      {:ok, _view, html} = live(conn, @url)

      assert text_of(html, ~s([data-testid="partial-answer"])) =~ "flezha@node-b did not answer"
      assert text_of(html, ~s([data-testid="relay-health"])) =~ "unknown"
    end

    test "a partition member shows its index, key range and group", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})

      # As the controller lists a member: inside its group's row.
      FakeController.set(node, {Relay, :list}, FakeController.rows([group_row("orders", 4)]))

      {:ok, _view, html} = live(conn, "/namespaces/default/relays/orders%23p1")

      assert html =~ ~s(data-testid="relay-partition")
      assert text_of(html, ~s([data-testid="relay-partition"])) =~ "Partition p1 of 4"
      assert html =~ "64–127"
      assert html =~ ~s(data-testid="relay-partition-group")
      assert html =~ "orders"
    end

    test "a relay with no partition shows no partition panel", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{})

      {:ok, _view, html} = live(conn, @url)

      refute html =~ ~s(data-testid="relay-partition")
      refute html =~ ~s(data-testid="partition-menu")
    end

    test "a partition member's menu opens each partition of its group on Live", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input"})
      partition_group(node, "orders", 3)

      {:ok, view, html} = live(conn, "/namespaces/default/relays/orders%23p1")

      assert text_of(html, ~s([data-testid="partition-menu"])) == "Partition p1 of 3"

      assert text_of(html, ~s([data-testid="partition-menu-orders#p2"])) =~
               "p2 · keys 128–191"

      assert has_element?(view, ~s([data-testid="partition-menu-orders#p1"][aria-checked="true"]))

      assert has_element?(
               view,
               ~s([data-testid="partition-menu-orders#p2"][aria-checked="false"])
             )

      refute has_element?(view, ~s([data-testid="partition-menu-relay_a"]))
      refute has_element?(view, ~s([data-testid="partition-menu-other#p0"]))

      assert {:error, {:live_redirect, %{to: "/namespaces/default/relays/orders%23p2"}}} =
               view |> element(~s([data-testid="partition-menu-orders#p2"])) |> render_click()
    end

    test "a relay absent from the rows still renders its overwatch facts", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input"})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "store_input"
      refute html =~ ~s(data-health=)
    end
  end

  describe "the overwatch panel" do
    test "renders what the controller reports about the relay", %{conn: conn, node: node} do
      overwatch(node, %{
        factory_id: "store_input",
        runner_id: "runner-a",
        started_at: System.system_time(:millisecond) - 60_000,
        phase: :running,
        effectively_once: true,
        default_input_type: "2"
      })

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "store_input"
      assert html =~ ~s(data-testid="relay-runner")
      assert html =~ "runner-a"
      assert html =~ ~s(data-testid="relay-run")
      assert html =~ ~s(data-testid="relay-uptime")
      assert html =~ ~s(data-testid="relay-effectively-once")
    end

    test "a steps relay's header links to its steps facts on State", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input", builder: %{run: :steps, opts: []}})
      {:ok, _view, html} = live(conn, @url)

      assert html =~
               ~r/href="\/namespaces\/default\/relays\/relay_a\/state#steps"[^>]*data-testid="relay-steps-link"|data-testid="relay-steps-link"[^>]*href="\/namespaces\/default\/relays\/relay_a\/state#steps"/
    end

    test "a relay that failed to initialise does not read as healthy", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input", halt_reason: :boom})
      registry_row(node, %{health: :healthy})

      {:ok, _view, html} = live(conn, @url)

      assert text_of(html, ~s([data-testid="relay-health"])) =~ "failed to initialise"
      refute text_of(html, ~s([data-testid="relay-health"])) =~ "healthy"
    end

    test "marks a suspended relay and says it cannot wake with no runner for its factory", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input", phase: :suspended})

      {:ok, view, html} = live(conn, @url)

      assert text_of(html, ~s([data-testid="relay-health"])) == "It is suspended."
      # Its condition opens by itself, as rows that agree with each other.
      assert has_element?(view, ~s([data-testid="relay-state"][data-state="suspended"]))

      assert condition_value(html, "relay-state", "runner") ==
               "None bound · 0 can run it (store_input)"

      assert condition_value(html, "relay-state", "handled") == "You"

      assert condition_value(html, "relay-state", "next") ==
               "Start a runner that serves store_input"

      refute condition_value(html, "relay-state", "next") =~ "Wakes"
    end

    test "runners that cannot take the relay wake nothing, whatever their count", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input", phase: :suspended})

      FakeController.set(
        node,
        {Flezha.Service.Fleet, :runners_for_factory},
        FakeController.rows(["runner-a"])
      )

      FakeController.set(
        node,
        {Flezha.Service.Relay, :diagnose},
        {:ok,
         %{
           relay: "relay_a",
           verdict: :problem,
           findings: [
             %{
               level: :problem,
               code: "diagnose.runner_mismatch",
               message:
                 "runners announce factory 'store_input', but none can take relay 'relay_a'",
               details: %{},
               hint: nil
             }
           ]
         }}
      )

      {:ok, view, _html} = live(conn, @url)
      html = view |> element(~s([data-testid="diagnose-btn"])) |> render_click()

      assert condition_value(html, "relay-state", "handled") == "You"

      assert condition_value(html, "relay-state", "next") ==
               "Start a runner that can take it"
    end

    test "a failed relay still naming the runner that left reads that you must start one", %{
      conn: conn,
      node: node
    } do
      registry_row(node, %{health: :failed})
      overwatch(node, %{factory_id: "store_input", runner_id: "gone"})

      {:ok, view, html} = live(conn, @url)

      assert condition_value(html, "relay-state", "runner") ==
               "gone bound · 0 can run it (store_input)"

      assert condition_value(html, "relay-state", "handled") == "You"
      assert has_element?(view, ~s([data-testid="talk-unavailable"]))
    end

    test "a relay bound to a runner is not asked about runners on each tick", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input", runner_id: "runner-a"})

      {:ok, view, _html} = live(conn, @url)
      send(view.pid, :refresh)
      render(view)

      assert FakeController.calls(node, {Flezha.Service.Fleet, :runners_for_factory}) == []
    end

    test "a suspended relay a runner serves wakes on the next message", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input", phase: :suspended})

      FakeController.set(
        node,
        {Flezha.Service.Fleet, :runners_for_factory},
        FakeController.rows(["runner-a"])
      )

      {:ok, _view, html} = live(conn, @url)

      assert condition_value(html, "relay-state", "runner") ==
               "None bound · 1 can run it (store_input)"

      assert condition_value(html, "relay-state", "handled") == "Nobody"

      assert condition_value(html, "relay-state", "next") ==
               "Wakes on the next message or its timer"
    end

    test "reports version skew by naming the missing call", %{conn: conn, node: node} do
      # Turning `control.unknown_function` into `:api_missing` is `NodeManager`'s
      # job and is covered in `node_manager_channel_test`; what matters here is that
      # the screen tells an operator the two have diverged rather than that
      # something merely broke.
      FakeController.set(
        node,
        {Relay, :overwatch_state},
        FakeController.error("control.unknown_function")
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "diverged"
      assert html =~ "overwatch_state/3"
      # Nobody read the runner, so the Condition does not say none is bound.
      refute html =~ ~s(data-testid="relay-state-runner")
    end
  end

  describe "recent activity" do
    @tail {Logs, :tail}

    defp history(node, records),
      do:
        FakeController.set(
          node,
          {Logs, :read},
          FakeController.log_page(records)
        )

    defp history_reads(node),
      do: node |> FakeController.calls({Logs, :read}) |> Enum.map(&hd/1)

    test "lists the relay's history on open and links to the whole of it", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{})
      history(node, [FakeController.history_record("relay_a")])

      {:ok, _view, html} = live(conn, @url)

      assert text_of(html, ~s([data-testid="recent-activity-sentence"])) =~
               "relay_a started from store_input, started by ops@acme through the UI"

      assert html =~ ~s(href="/logs/relay_history?namespace=default&amp;relay=relay_a")

      assert [params] =
               node |> history_reads() |> Enum.filter(&(&1["limit"] == 5))

      assert params["kind"] == "relay_history"
      assert params["filters"] == %{"namespace" => "default", "relay" => "relay_a"}
    end

    test "says when nothing is recorded for the relay yet", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="recent-activity-empty")
    end

    test "an ended record arrives at the top while the screen is open, without a read", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{})
      history(node, [FakeController.history_record("relay_a")])

      {:ok, view, _html} = live(conn, @url)
      assert FakeController.eventually(fn -> FakeController.streams(node, @tail) != [] end)

      assert [[params, _ctx]] = FakeController.calls(node, @tail)
      assert params["kind"] == "relay_history"
      assert params["filters"] == %{"namespace" => "default", "relay" => "relay_a"}
      reads = length(FakeController.calls(node, {Logs, :read}))

      ended =
        FakeController.history_record("relay_a", %{
          "event" => "ended",
          "outcome" => "completed",
          "duration_ms" => 3_000
        })

      FakeController.emit(node, @tail, ended)

      assert FakeController.eventually(fn ->
               view
               |> render()
               |> text_of(~s([data-testid="recent-activity-sentence"]))
               |> String.starts_with?("relay_a finished: completed after 3 s")
             end)

      assert length(FakeController.calls(node, {Logs, :read})) == reads
    end

    test "lets go of its tail while the page is hidden and reads afresh when it shows", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{})

      {:ok, view, _html} = live(conn, @url)
      assert FakeController.eventually(fn -> FakeController.streams(node, @tail) != [] end)
      reads = length(history_reads(node) |> Enum.filter(&(&1["limit"] == 5)))

      render_hook(view, "refresh_visibility", %{"hidden" => true})
      assert FakeController.eventually(fn -> FakeController.streams(node, @tail) == [] end)

      render_hook(view, "refresh_visibility", %{"hidden" => false})
      assert FakeController.eventually(fn -> FakeController.streams(node, @tail) != [] end)

      assert length(history_reads(node) |> Enum.filter(&(&1["limit"] == 5))) == reads + 1
      assert length(FakeController.calls(node, @tail)) == 2
    end

    test "a refused read is stated in the strip, the rest of the screen kept", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{factory_id: "store_input"})
      registry_row(node, %{})
      FakeController.set(node, {Logs, :read}, FakeController.error("authz.role_insufficient"))

      {:ok, _view, html} = live(conn, @url)

      strip = text_of(html, ~s([data-testid="recent-activity"]))
      assert strip =~ "authz.role_insufficient"
      refute html =~ ~s(data-testid="recent-activity-empty")
      assert html =~ ~s(data-testid="topology-graph")
    end
  end

  describe "a finished relay" do
    defp finished(node, completion) do
      FakeController.set(node, {Relay, :overwatch_state}, FakeController.error("relay.not_found"))

      ended =
        FakeController.history_record("relay_a", %{
          "event" => "ended",
          "outcome" => "undone",
          "duration_ms" => 41_000,
          "error" => "step 3 refused",
          "origin" => %{"kind" => "spawn", "parent_relay" => "ma_fan"}
        })

      FakeController.set(
        node,
        {Logs, :read},
        FakeController.log_page([ended])
      )

      FakeController.set(node, {Flezha.Service.Steps, :completion}, completion)
    end

    test "whose state was kept shows its last run, until when it is kept, and no live action", %{
      conn: conn,
      node: node
    } do
      expires_at = System.system_time(:second) + 3_600

      finished(
        node,
        {:ok,
         %{
           status: "error",
           finished_at: System.system_time(:second),
           state_kept: true,
           expires_at: expires_at
         }}
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="finished-run")
      outcome = text_of(html, ~s([data-testid="finished-outcome"]))
      assert outcome =~ "undone"
      assert outcome =~ "compensated"
      assert text_of(html, ~s([data-testid="finished-duration"])) =~ "41 s"
      assert text_of(html, ~s([data-testid="finished-origin"])) =~ "Spawned by ma_fan"
      assert html =~ "step 3 refused"

      state = text_of(html, ~s([data-testid="finished-state"]))
      assert state =~ "kept until"
      assert html =~ ~s(href="/namespaces/default/relays/relay_a/state")

      refute html =~ ~s(data-testid="stop-relay-btn")
      refute html =~ ~s(data-testid="talk-open-btn")
      refute html =~ ~s(data-testid="calls-panel")

      # The last run is read by its `ended` record on mount, never on a tick.
      last_runs =
        node
        |> FakeController.calls({Logs, :read})
        |> Enum.map(&hd/1)
        |> Enum.filter(&(&1["limit"] == 1))

      assert last_runs != []

      assert Enum.all?(
               last_runs,
               &(&1["filters"] == %{
                   "namespace" => "default",
                   "relay" => "relay_a",
                   "event" => "ended"
                 })
             )

      completions = FakeController.calls(node, {Flezha.Service.Steps, :completion})
      assert completions != []
      assert Enum.all?(completions, &match?(["relay_a", %{token: _}], &1))
    end

    test "whose state was not kept says so and how a factory keeps it", %{conn: conn, node: node} do
      finished(node, {:ok, %{status: "error", finished_at: 1_700_000_000, state_kept: false}})

      {:ok, _view, html} = live(conn, @url)

      state = text_of(html, ~s([data-testid="finished-state"]))
      assert state =~ "Its state was not kept"
      assert state =~ "keep_finished"
      refute state =~ "Read it on State"
      refute html =~ ~s(data-testid="stop-relay-btn")
    end

    test "with neither a live row nor an ended record is reported as not found", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Relay, :overwatch_state}, FakeController.error("relay.not_found"))

      {:ok, _view, html} = live(conn, @url)

      refute html =~ ~s(data-testid="finished-run")
      assert html =~ ~s(data-testid="runtime-error")
      assert html =~ "relay.not_found"
    end
  end

  describe "plugin bindings" do
    test "lists the hooks bound on the relay", %{conn: conn, node: node} do
      overwatch(node, %{
        factory_id: "store_input",
        extensions: FakeController.hook_table("plug_1")
      })

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "plugins")

      assert html =~ ~s(data-testid="bindings-panel")
      assert html =~ ~s(data-testid="bindings-table")
      assert html =~ ~s(data-testid="binding-row-plug_1")
      assert html =~ "Flezha.Plugin.Provider.StdOut"
      assert html =~ "on_input"
    end

    test "explains a relay with no plugins", %{conn: conn, node: node} do
      overwatch(node, %{factory_id: "store_input"})

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "plugins")

      assert html =~ ~s(data-testid="no-plugins-msg")
    end

    test "a declared binding that is not running is listed and can be unbound", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{
        factory_id: "store_input",
        extensions: FakeController.hook_table("plug_1")
      })

      FakeController.set(
        node,
        {Flezha.Service.Relay, :relay_plugins},
        FakeController.rows([
          {"relay_a",
           [
             {"plug_1", %{hooks: [on_input: []], provider: Flezha.Plugin.Provider.StdOut}},
             {"gone_1", %{hooks: [on_output: []], provider: Flezha.Plugin.Provider.StdOut}}
           ]}
        ])
      )

      {:ok, view, _html} = live(conn, @url)
      html = open_section(view, "plugins")

      assert html =~ ~s(data-testid="binding-idle-gone_1")
      refute html =~ ~s(data-testid="binding-idle-plug_1")

      view |> element(~s([data-testid="unbind-btn-gone_1"])) |> render_click()
      view |> element(~s([data-testid="unbind-confirm-btn"])) |> render_click()

      assert [["gone_1", %{"namespace" => "default", "relay_id" => "relay_a"}, %{token: _}]] =
               FakeController.calls(node, {PluginManager, :unbind})
    end

    test "confirming unbinds this relay alone and leaves the plugin enabled", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{
        factory_id: "store_input",
        extensions: FakeController.hook_table("plug_1")
      })

      {:ok, view, _html} = live(conn, @url)
      open_section(view, "plugins")
      view |> element(~s([data-testid="unbind-btn-plug_1"])) |> render_click()

      assert view |> element(~s([data-testid="unbind-confirm-btn"])) |> render_click() =~
               "relay_a unbound from plugin plug_1."

      assert [["plug_1", %{"namespace" => "default", "relay_id" => "relay_a"}, %{token: _}]] =
               FakeController.calls(node, {PluginManager, :unbind})

      assert FakeController.calls(node, {PluginManager, :disable}) == []
    end

    test "a refused unbind is reported rather than shown as success", %{
      conn: conn,
      node: node
    } do
      overwatch(node, %{
        factory_id: "store_input",
        extensions: FakeController.hook_table("plug_1")
      })

      FakeController.set(
        node,
        {PluginManager, :unbind},
        FakeController.error("plugin.not_found")
      )

      {:ok, view, _html} = live(conn, @url)
      open_section(view, "plugins")
      view |> element(~s([data-testid="unbind-btn-plug_1"])) |> render_click()

      html = view |> element(~s([data-testid="unbind-confirm-btn"])) |> render_click()
      assert html =~ "plugin.not_found (test)"
      refute html =~ "unbound from"
    end
  end

  describe "attaching a plugin" do
    setup %{node: node} do
      overwatch(node, %{factory_id: "store_input"})

      FakeController.set(
        node,
        {Fleet, :providers},
        {:ok,
         %{
           rows: [%{id: "relay_stdout", module: "Flezha.Plugin.Provider.StdOut", type: :io}],
           refused: %{},
           unreachable: []
         }}
      )

      FakeController.set(
        node,
        {Fleet, :provider},
        {:ok,
         %{
           provider: "relay_stdout",
           help: "Writes each output to stdout.",
           type: :io,
           hooks: [:on_input, :on_output]
         }}
      )

      :ok
    end

    test "offers the provider's own hooks and help", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)

      assert open_attach(view) =~ ~s(data-testid="provider-btn-relay_stdout")
      html = choose_stdout(view)

      assert html =~ ~s(data-testid="input-hook-on_input")
      assert html =~ ~s(data-testid="input-hook-on_output")
      assert html =~ "Writes each output to stdout."
    end

    test "enables the plugin by name, bound to this relay, with text-keyed options", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @url)
      open_attach(view)
      choose_stdout(view)

      html =
        submit_plugin_form(view,
          name: "out_1",
          hooks: ["", "on_output"],
          opts: ~s({"prefix": "out"})
        )

      assert html =~ "Plugin out_1 enabled and bound to relay_a."

      assert [["out_1", fields, %{token: _}]] =
               FakeController.calls(node, {PluginManager, :enable})

      assert fields["provider"] == "relay_stdout"
      assert fields["opts"] == %{"prefix" => "out"}
      assert fields["namespace"] == "default"
      assert fields["relay_id"] == "relay_a"
      assert fields["hooks"] == ["on_output"]
    end

    test "options that are not a JSON object are refused before any call", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @url)
      open_attach(view)
      choose_stdout(view)

      html = submit_plugin_form(view, name: "out_1", opts: "[1, 2]")

      assert html =~ "Options must be a JSON object."
      assert FakeController.calls(node, {PluginManager, :enable}) == []
    end

    test "a plugin already enabled is reported as bound", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {PluginManager, :enable},
        {:ok, %{name: "out_1", outcome: :already_enabled, bound: "relay_a", lacking: []}}
      )

      {:ok, view, _html} = live(conn, @url)
      open_attach(view)
      choose_stdout(view)

      assert submit_plugin_form(view, name: "out_1") =~
               "Plugin out_1 was already enabled; this relay is bound to it."
    end

    test "offers the namespace's enabled plugins it does not hold and binds one as it is", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Fleet, :providers},
        {:ok,
         %{
           rows: [
             %{id: "relay_stdout", module: "Flezha.Plugin.Provider.StdOut", type: :io},
             %{id: "hook_webhook", module: "Flezha.Plugin.Provider.Webhook", type: :controller}
           ],
           refused: %{},
           unreachable: []
         }}
      )

      enabled = fn name, provider, relays ->
        %{
          name: name,
          provider: provider,
          provider_id: provider,
          relays: relays,
          hooks: ["on_output"]
        }
      end

      FakeController.set(
        node,
        {PluginManager, :enabled},
        {:ok,
         [
           enabled.("out_1", "relay_stdout", ["relay_b"]),
           enabled.("out_2", "relay_stdout", ["relay_a"]),
           enabled.("hooks_1", "hook_webhook", [])
         ]}
      )

      {:ok, view, _html} = live(conn, @url)
      html = open_attach(view)

      assert html =~ ~s(data-testid="enabled-btn-out_1")
      refute html =~ ~s(data-testid="enabled-btn-out_2")
      refute html =~ ~s(data-testid="enabled-btn-hooks_1")

      html = view |> element(~s([data-testid="enabled-btn-out_1"])) |> render_click()
      assert html =~ "Bind out_1 to relay_a"
      assert has_element?(view, ~s([data-testid="input-hook-on_output"][checked]))
      refute has_element?(view, ~s([data-testid="input-plugin-relay"]))

      assert submit_plugin_form(view, %{}) =~ "Plugin out_1 bound to relay_a."

      assert [["out_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :bind})
      assert fields["relay_id"] == "relay_a"
      assert fields["hooks"] == ["on_output"]
      assert FakeController.calls(node, {PluginManager, :enable}) == []
    end

    test "a rejected plugin states the controller's error on the form", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {PluginManager, :enable},
        FakeController.error("plugin.unknown_options", "a relay_stdout plugin has no option x")
      )

      {:ok, view, _html} = live(conn, @url)
      open_attach(view)
      choose_stdout(view)

      html = submit_plugin_form(view, name: "out_1")
      assert html =~ ~s(data-testid="attach-error")
      assert html =~ "a relay_stdout plugin has no option x"
    end
  end

  describe "the payload tap" do
    setup %{node: node} do
      overwatch(node, %{factory_id: "store_input"})
      FakeController.set(node, {Relay, :graph}, FakeController.one_tasklet_graph("relay_a"))
      :ok
    end

    test "a tap whose listen ended says so", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      view |> element(~s([data-testid="topo-node-exit-out"])) |> render_click()

      key = {Relay, :listen}
      assert FakeController.eventually(fn -> FakeController.streams(node, key) != [] end)

      FakeController.end_stream(node, key, {:ok, :relay_ended})

      assert FakeController.eventually(fn -> render(view) =~ ~s(data-testid="tap-ended") end)
      refute render(view) =~ "Waiting for a record"
    end
  end

  describe "stopping the relay" do
    setup %{node: node} do
      overwatch(node, %{factory_id: "store_input"})
      :ok
    end

    test "confirming stops it and returns to the namespace", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)

      {:ok, _view, html} = view |> stop() |> follow_redirect(conn, "/namespaces/default")

      assert html =~ "Relay relay_a stopped."

      assert [["default", "relay_a", %{token: _}]] = FakeController.calls(node, {Relay, :stop})
    end

    test "a cooperative stop says the relay finishes its in-flight work", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :stop},
        {:ok, %{id: "relay_a", stopped: :cooperative}}
      )

      {:ok, view, _html} = live(conn, @url)

      {:ok, _view, html} = view |> stop() |> follow_redirect(conn, "/namespaces/default")

      assert html =~ "finishes its in-flight work"
    end

    test "a refused stop keeps the operator on the screen", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :stop}, FakeController.error("relay.not_running"))

      {:ok, view, _html} = live(conn, @url)

      assert stop(view) =~ "relay.not_running (test)"
    end
  end

  # The SDK state read sits on the State tab.
  describe "reading cell state" do
    setup %{node: node} do
      overwatch(node, %{factory_id: "store_input"})
      :ok
    end

    test "renders the state the controller returned", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :cell_state}, {:ok, ~s({"balance":42}), 7})

      {:ok, view, _html} = live(conn, @url <> "/state")
      open_section(view, "sdk-state")
      html = fetch_state(view)

      assert html =~ ~s(data-testid="sdk-state-panel")
      assert html =~ ~s(data-testid="state-json")
      assert html =~ "balance"
    end

    test "narrows the read to one cell as the operator fills in both", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @url <> "/state")
      open_section(view, "sdk-state")

      select_cell(view, %{tasklet: "charge", cell_key: "cust-9"})

      fetch_state(view)

      assert [["default", "relay_a", "charge/cust-9", %{token: _}]] =
               FakeController.calls(node, {Relay, :cell_state})
    end

    test "no tasklet reads every cell", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url <> "/state")
      fetch_state(view)

      assert [["default", "relay_a", nil, %{token: _}]] =
               FakeController.calls(node, {Relay, :cell_state})
    end

    test "a cell key without a tasklet makes no read", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url <> "/state")
      open_section(view, "sdk-state")

      select_cell(view, %{cell_key: "cust-9"})
      html = fetch_state(view)

      assert html =~ "name the tasklet too"
      assert FakeController.calls(node, {Relay, :cell_state}) == []
    end

    test "explains a relay that keeps no state", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :cell_state},
        FakeController.error("state.persistence_off")
      )

      {:ok, view, _html} = live(conn, @url <> "/state")
      open_section(view, "sdk-state")

      html = fetch_state(view)
      assert html =~ ~s(data-testid="state-notice")
      assert html =~ "persistence off"
    end

    test "explains cells that are not held in memory", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :cell_state}, FakeController.error("state.not_resident"))

      {:ok, view, _html} = live(conn, @url <> "/state")
      open_section(view, "sdk-state")

      assert fetch_state(view) =~ "not held in memory"
    end
  end

  defp stop(view) do
    view |> element(~s([data-testid="stop-relay-btn"])) |> render_click()
    view |> element(~s([data-testid="stop-confirm-btn"])) |> render_click()
  end

  defp fetch_state(view),
    do: view |> element(~s([data-testid="fetch-state-btn"])) |> render_click()

  defp select_cell(view, selector) do
    view
    |> form(~s(form[phx-change="selector_change"]), selector: selector)
    |> render_change()
  end

  defp choose_stdout(view),
    do: view |> element(~s([data-testid="provider-btn-relay_stdout"])) |> render_click()

  # The relay screen opens the shared plugin form with this relay fixed.
  defp open_attach(view),
    do: view |> element(~s([data-testid="attach-plugin-btn"])) |> render_click()
end
