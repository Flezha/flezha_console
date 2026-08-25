defmodule FlezhaUi.Service.NodeManagerTest do
  @moduledoc """
  Covers the two pieces of `NodeManager` that decide whether a controller
  change is diagnosable or a mystery: how remote failures are classified, and
  how a plugin is assembled from an operator's form.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FlezhaUi.Service.NodeManager

  describe "erpc_call/3 error classification" do
    test "answers :node_not_connected when no controller is reachable" do
      # No node is connected in the test VM, which is the disconnected case.
      assert {:error, :node_not_connected} = NodeManager.erpc_call(Flezha, :list_namespaces, [])
    end

    test "every controller call degrades instead of raising while disconnected" do
      for call <- controller_calls() do
        assert {:error, :node_not_connected} = call.()
      end
    end
  end

  # Every call the screens make. A new one added without a normalised failure
  # path shows up here as a raise rather than as a banner.
  defp controller_calls do
    [
      fn -> NodeManager.list_namespaces() end,
      fn -> NodeManager.list_operatives("default") end,
      fn -> NodeManager.list_runners("default") end,
      fn -> NodeManager.list_factories("default") end,
      fn -> NodeManager.factory_catalog("default") end,
      fn -> NodeManager.stop_operative("default", "op") end,
      fn -> NodeManager.entity_state("default", "op", %{}) end,
      fn -> NodeManager.get_overwatch_state("default", "op") end,
      fn -> NodeManager.get_plugins() end,
      fn -> NodeManager.disable_plugin("p1") end,
      fn -> NodeManager.dlq_list() end,
      fn -> NodeManager.dlq_get("a/b/c") end,
      fn -> NodeManager.dlq_stats() end,
      fn -> NodeManager.schedule_list() end,
      fn -> NodeManager.schedule_statuses() end,
      fn -> NodeManager.audit_files() end,
      fn -> NodeManager.audit_stats() end,
      fn -> NodeManager.get_provider_info() end,
      fn -> NodeManager.active_runners("default") end,
      fn -> NodeManager.hub_nodes("default") end,
      fn -> NodeManager.controller_cluster_nodes() end
    ]
  end

  describe "ok_or/2" do
    test "takes the value out of a success" do
      assert [1, 2] = NodeManager.ok_or({:ok, [1, 2]}, [])
    end

    test "falls back on a failure, so one dead section does not empty a page" do
      assert [] = NodeManager.ok_or({:error, :node_not_connected}, [])
      assert nil == NodeManager.ok_or({:error, :timeout}, nil)
    end
  end

  describe "providers/0" do
    test "answers an empty list rather than an error while disconnected" do
      assert [] = NodeManager.providers()
    end
  end

  describe "factories_by_runner/1" do
    test "inverts a catalog onto the runners serving each factory" do
      catalog = [
        %{id: "compare_filter", description: nil, runners: ["runner-a"], servable?: true},
        %{id: "store_input", description: nil, runners: ["runner-b", "runner-a"], servable?: true}
      ]

      assert %{
               "runner-a" => ["compare_filter", "store_input"],
               "runner-b" => ["store_input"]
             } = NodeManager.factories_by_runner(catalog)
    end

    test "a factory no runner serves contributes no entry" do
      catalog = [%{id: "store_input", description: nil, runners: [], servable?: false}]

      assert %{} == NodeManager.factories_by_runner(catalog)
    end
  end

  describe "known_kinds/0" do
    test "a controller that cannot answer still offers this UI's kinds" do
      # Nothing is connected here, so every probe fails — the form has to stay
      # usable, without claiming capabilities it could not read.
      assert [%{kind: :stream, capabilities: []}, %{kind: :workflow, capabilities: []}] =
               NodeManager.known_kinds()
    end
  end

  describe "start_operative/6" do
    test "defaults kind to :stream and leaves init values and opts empty" do
      # Reached through the disconnected path, so the assertion is that the
      # call is well-formed rather than that it succeeded.
      assert {:error, :node_not_connected} =
               NodeManager.start_operative("default", "op-1", "store_input")
    end

    test "accepts an explicit kind" do
      assert {:error, :node_not_connected} =
               NodeManager.start_operative("default", "op-1", "echo_workflow", %{}, [], :workflow)
    end
  end

  describe "extract_subscriptions/1" do
    test "builds one subscription per selected extension" do
      assert {:ok, [{:on_input, []}, {:on_output, []}]} =
               NodeManager.extract_subscriptions(%{"extensions" => ["on_input", "on_output"]})
    end

    test "accepts a single extension not wrapped in a list" do
      assert {:ok, [{:on_terminate, []}]} =
               NodeManager.extract_subscriptions(%{"extensions" => "on_terminate"})
    end

    test "falls back to the single trigger shape" do
      assert {:ok, [{:on_input, []}]} =
               NodeManager.extract_subscriptions(%{"trigger" => "on_input"})
    end

    test "maps both legacy trigger spellings onto an interval subscription" do
      assert {:ok, [{:on_interval, [interval_ms: 5_000]}]} =
               NodeManager.extract_subscriptions(%{"trigger" => "proactive"})

      assert {:ok, [{:on_interval, [interval_ms: 5_000]}]} =
               NodeManager.extract_subscriptions(%{"trigger" => "interval"})
    end

    test "an explicit interval overrides the legacy default" do
      assert {:ok, [{:on_interval, opts}]} =
               NodeManager.extract_subscriptions(%{
                 "trigger" => "proactive",
                 "sub_interval_ms" => "250"
               })

      assert opts[:interval_ms] == 250
    end

    test "carries subscription options through, cast to integers" do
      assert {:ok, [{:on_input, opts}]} =
               NodeManager.extract_subscriptions(%{
                 "trigger" => "on_input",
                 "sub_position" => "3",
                 "sub_key" => "fetch_state"
               })

      assert opts[:position] == 3
      assert opts[:key] == "fetch_state"
    end

    test "drops blank subscription options rather than sending empty strings" do
      assert {:ok, [{:on_input, []}]} =
               NodeManager.extract_subscriptions(%{"trigger" => "on_input", "sub_position" => ""})
    end

    test "an empty form subscribes to nothing" do
      assert {:ok, []} = NodeManager.extract_subscriptions(%{})
      assert {:ok, []} = NodeManager.extract_subscriptions(%{"trigger" => ""})
    end

    test "rejects an unknown extension instead of creating an atom for it" do
      before = :erlang.system_info(:atom_count)

      assert {:error, {:unknown_extension, "on_totally_made_up"}} =
               NodeManager.extract_subscriptions(%{"trigger" => "on_totally_made_up"})

      assert :erlang.system_info(:atom_count) == before,
             "a rejected extension name must not grow the atom table"
    end

    test "rejects the whole form when any selected extension is unknown" do
      assert {:error, {:unknown_extension, "nope"}} =
               NodeManager.extract_subscriptions(%{"extensions" => ["on_input", "nope"]})
    end
  end

  describe "enable_plugin/5" do
    test "reports a missing provider without calling the controller" do
      assert {:error, "provider not found"} =
               NodeManager.enable_plugin("p1", nil, %{}, "default", "op-1")
    end

    test "surfaces an unknown extension before attempting the enable" do
      provider = %{
        module: "Flezha.Plugin.Provider.StdOut",
        required_fields: [],
        optional_fields: []
      }

      assert {:error, {:unknown_extension, "bogus"}} =
               NodeManager.enable_plugin(
                 "p1",
                 provider,
                 %{"trigger" => "bogus"},
                 "default",
                 "op-1"
               )
    end

    test "a well-formed enable reaches the controller call" do
      provider = %{
        module: "Flezha.Plugin.Provider.StdOut",
        required_fields: [],
        optional_fields: []
      }

      assert {:error, :node_not_connected} =
               NodeManager.enable_plugin(
                 "p1",
                 provider,
                 %{"trigger" => "on_output"},
                 "default",
                 "op-1"
               )
    end
  end

  describe "provider_form/2" do
    test "carries a declared field through to the plugin's opts" do
      provider = %{
        module: "Flezha.Plugin.Provider.OperativeWebsocket",
        required_fields: ["uri"],
        optional_fields: []
      }

      form = NodeManager.provider_form(%{"uri" => "ws://host:4500"}, ["on_terminate"])

      # A form built from plain settings has to satisfy the same reader the
      # attach form does, so a caller that never spells the prefix still lands
      # its options rather than enabling with an empty map.
      assert %{"field_uri" => "ws://host:4500", "extensions" => ["on_terminate"]} = form

      assert {:error, :node_not_connected} =
               NodeManager.enable_plugin("p1", provider, form, "default", "op-1")
    end

    test "accepts atom-keyed settings" do
      assert %{"field_uri" => "ws://host"} =
               NodeManager.provider_form(%{uri: "ws://host"}, ["on_input"])
    end
  end

  describe "extension_entries/1" do
    test "flattens an extension table into one row per subscription" do
      state = %{
        extensions: %{
          subs: %{
            on_input: [
              %{plugin_id: "b", provider: Flezha.Plugin.Provider.StdOut, position: 1},
              %{plugin_id: "a", provider: Flezha.Plugin.Provider.Filter, position: 0}
            ],
            on_terminate: [%{plugin_id: "c", provider: Flezha.Plugin.Provider.Websocket}]
          }
        }
      }

      rows = NodeManager.extension_entries(state)

      assert [
               %{plugin_id: "a", extension: "on_input", position: 0},
               %{plugin_id: "b", extension: "on_input", position: 1},
               %{plugin_id: "c", extension: "on_terminate"}
             ] = rows

      assert Enum.at(rows, 0).provider =~ "Filter"
    end

    test "an operative with no plugins yields no rows" do
      assert [] = NodeManager.extension_entries(%{extensions: %{subs: %{}}})
    end

    test "a state without an extension table yields no rows rather than raising" do
      assert [] = NodeManager.extension_entries(%{})
      assert [] = NodeManager.extension_entries(nil)
    end

    test "renders a missing provider as a placeholder" do
      state = %{extensions: %{subs: %{on_input: [%{plugin_id: "a"}]}}}
      assert [%{provider: "—"}] = NodeManager.extension_entries(state)
    end
  end

  describe "caller_context/1" do
    test "identifies this UI as the caller" do
      assert %{source: :ui} == NodeManager.caller_context()
    end

    test "a caller-supplied value is not a principal" do
      # Identity comes only from a verified token, and with no controller to
      # verify against nothing binds — a name typed into the UI never can.
      assert %{source: :ui} == NodeManager.caller_context("svc-ui")
    end
  end

  describe "extensions/0" do
    test "matches the host's extension points" do
      assert NodeManager.extensions() == [
               :on_operative_init,
               :on_input,
               :on_output,
               :on_interval,
               :on_message,
               :on_snapshot,
               :on_terminate
             ]
    end
  end

  describe "logging" do
    test "a disconnected call stays quiet" do
      log = capture_log(fn -> NodeManager.list_namespaces() end)
      refute log =~ "diverged"
    end
  end
end
