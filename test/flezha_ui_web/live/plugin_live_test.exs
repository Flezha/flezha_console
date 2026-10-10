defmodule FlezhaUiWeb.PluginLiveTest do
  @moduledoc """
  The plugins screen: the plugins enabled in each reachable namespace, the
  relays bound to each, the providers on offer and the installed packages.

  A refused namespace, an unavailable installer and a plugin bound to no relay
  are states a live controller will not be put into on demand, which is why
  they are produced here.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay

  defp plugin(name, overrides \\ %{}) do
    Map.merge(
      %{
        name: name,
        provider: "std_out",
        provider_id: "relay_stdout",
        single: false,
        relays: ["relay_a"],
        controllers: [],
        hooks: ["on_output"],
        lagging: []
      },
      overrides
    )
  end

  defp with_namespaces(node, plugins_by_namespace) do
    catalog = Enum.map(Map.keys(plugins_by_namespace), &%{namespace: &1, running: true})
    FakeController.set(node, {Relay, :list_namespaces}, {:ok, catalog})

    FakeController.set(
      node,
      {PluginManager, :enabled},
      {:per_arg, 0, plugins_by_namespace, {:ok, []}}
    )
  end

  describe "listing" do
    test "renders the empty state when nothing is enabled", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ ~s(data-testid="plugins-empty")
      refute html =~ ~s(data-testid="plugin-row-)
    end

    test "lists each enabled plugin with provider, namespace, relays and hooks", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, %{"default" => {:ok, [plugin("plug_1")]}})

      {:ok, view, _html} = live(conn, ~p"/plugins")

      row = view |> element(~s([data-testid="plugin-row-plug_1"])) |> render()
      assert row =~ "std_out"
      assert row =~ "default"
      assert row =~ "relay_a"
      assert row =~ "on_output"
    end

    test "reads each reachable namespace with its own call", %{conn: conn, node: node} do
      with_namespaces(node, %{
        "default" => {:ok, [plugin("plug_1")]},
        "staging" => {:ok, [plugin("plug_2")]}
      })

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ ~s(data-testid="plugin-row-plug_1")
      assert html =~ ~s(data-testid="plugin-row-plug_2")

      asked = node |> FakeController.calls({PluginManager, :enabled}) |> Enum.map(&hd/1)
      assert Enum.sort(Enum.uniq(asked)) == ["default", "staging"]
    end

    test "a plugin bound to no relay shows a placeholder", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, [plugin("plug_1", %{relays: []})]}})

      {:ok, view, _html} = live(conn, ~p"/plugins")

      assert view |> element(~s([data-testid="plugin-relays-plug_1"])) |> render() =~ "—"
    end

    test "one refused namespace is stated while the others still list", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, %{
        "default" => {:ok, [plugin("plug_1")]},
        "secret" => FakeController.error("authz.namespace_mismatch")
      })

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ ~s(data-testid="plugin-row-plug_1")
      assert html =~ ~s(data-testid="plugins-refused-secret")
      assert html =~ "authz.namespace_mismatch"
    end

    test "the scoped screen reads its namespace alone", %{conn: conn, node: node} do
      with_namespaces(node, %{
        "default" => {:ok, [plugin("plug_1")]},
        "staging" => {:ok, [plugin("plug_2")]}
      })

      {:ok, _view, html} = live(conn, ~p"/namespaces/staging/plugins")

      assert html =~ ~s(data-testid="plugin-row-plug_2")
      refute html =~ ~s(data-testid="plugin-row-plug_1")

      assert node
             |> FakeController.calls({PluginManager, :enabled})
             |> Enum.all?(&match?(["staging", _ctx], &1))
    end
  end

  describe "available providers" do
    test "lists the providers the controller offers, by id", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :providers},
        {:ok,
         %{
           providers: [
             %{id: "relay_stdout", module: "Flezha.Plugin.Provider.StdOut", type: :relay},
             %{id: "relay_websocket", module: "Flezha.Plugin.Provider.Websocket", type: :relay}
           ],
           refused: 0
         }}
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ ~s(data-testid="provider-relay_stdout")
      assert html =~ ~s(data-testid="provider-relay_websocket")
    end

    test "a refused provider listing is stated", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :providers},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ "authz.role_insufficient"
    end
  end

  describe "disabling a plugin" do
    setup %{node: node} do
      with_namespaces(node, %{"default" => {:ok, [plugin("plug_1")]}})
      :ok
    end

    test "is confirm-gated, and cancelling reaches nothing", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/plugins")

      render_click(view, "confirm_disable", %{"name" => "plug_1", "namespace" => "default"})
      render_click(view, "cancel_disable", %{})

      assert FakeController.calls(node, {PluginManager, :disable}) == []
    end

    test "confirming disables it by name in its namespace", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/plugins")
      render_click(view, "confirm_disable", %{"name" => "plug_1", "namespace" => "default"})

      assert render_click(view, "disable_plugin", %{"name" => "plug_1", "namespace" => "default"}) =~
               "Plugin plug_1 disabled."

      assert [["plug_1", [namespace: "default"], %{source: :ui}]] =
               FakeController.calls(node, {PluginManager, :disable})
    end

    test "a plugin the controller does not know is reported as such", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {PluginManager, :disable},
        FakeController.error("plugin.not_found")
      )

      {:ok, view, _html} = live(conn, ~p"/plugins")
      render_click(view, "confirm_disable", %{"name" => "plug_1", "namespace" => "default"})

      assert render_click(view, "disable_plugin", %{"name" => "plug_1", "namespace" => "default"}) =~
               "The controller does not know a plugin named plug_1."
    end
  end

  describe "installed catalog" do
    test "installed packages are listed with id, version and load status", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Fleet, :installed_plugins},
        {:ok,
         [
           %{id: "kafka", version: "1.2.0", status: :loaded, error: nil},
           %{
             id: "s3",
             version: "0.9.0",
             status: :refused,
             providers: ["file_s3"],
             error: refusal("digest mismatch")
           }
         ]}
      )

      {:ok, view, html} = live(conn, ~p"/plugins")

      assert html =~ ~s(data-testid="installed-kafka")
      assert html =~ "1.2.0"
      assert view |> element(~s([data-testid="installed-status-s3"])) |> render() =~ "refused"
      assert html =~ "digest mismatch"
    end

    test "no control installs, upgrades or uninstalls, and flz is named", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ "flz plugin"
      refute html =~ "phx-click=\"install_plugin\""
      refute html =~ "phx-click=\"uninstall_plugin\""
      refute html =~ "phx-click=\"upgrade_plugin\""
    end

    test "an unavailable installer states so and the enabled list still renders", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, %{"default" => {:ok, [plugin("plug_1")]}})

      FakeController.set(
        node,
        {Fleet, :installed_plugins},
        {:error, {:api_missing, Fleet, :installed_plugins, 1}}
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ ~s(data-testid="catalog-unavailable")
      assert html =~ ~s(data-testid="plugin-row-plug_1")
    end
  end

  describe "a refused or pending package" do
    test "a refused package shows its error's code, message and hint", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :installed_plugins},
        {:ok,
         [
           %{id: "http", version: "1.0.0", status: :loaded, providers: ["http_push"], error: nil},
           %{
             id: "s3",
             version: "0.9.0",
             status: :refused,
             providers: ["file_s3"],
             error: refusal("bad manifest")
           }
         ]}
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ ~r/data-testid="installed-providers-http"[^>]*>\s*http_push/
      assert html =~ ~s(data-testid="installed-error-s3")
      assert html =~ "bad manifest (plugin.package_invalid)"
      assert html =~ "flz plugin install --force"
      assert html =~ ~s(href="https://docs.flezha.com/errors.html#plugin")
    end

    # The controller lists only the providers of packages it loaded.
    test "the enable form offers the providers the controller lists", %{conn: conn, node: node} do
      providers(node, [provider("relay_stdout", :relay)], 1)
      {:ok, view, _html} = live(conn, ~p"/plugins")

      html = open_enable(view)

      assert html =~ ~s(data-testid="provider-btn-relay_stdout")
      assert length(Regex.scan(~r/data-testid="provider-btn-/, html)) == 1
    end

    test "a pending package shows the version still loaded", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :installed_plugins},
        {:ok,
         [
           %{
             id: "http",
             version: "1.1.0",
             status: :pending,
             loaded_version: "1.0.0",
             providers: [],
             error: nil
           }
         ]}
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ ~r/data-testid="installed-loaded-http"[^>]*>\s*1.0.0 still loaded/
    end

    test "the provider listing states how many packages were refused", %{conn: conn, node: node} do
      providers(node, [provider("relay_stdout", :relay)], 2)

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ ~s(data-testid="providers-refused")
      assert html =~ "refused 2 installed packages"
    end

    test "nothing refused, nothing stated", %{conn: conn, node: node} do
      providers(node, [provider("relay_stdout", :relay)], 0)

      {:ok, _view, html} = live(conn, ~p"/plugins")

      refute html =~ ~s(data-testid="providers-refused")
    end
  end

  describe "enabling a plugin" do
    test "a relay provider asks for a relay and offers its relay hooks", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}})
      providers(node, [provider("relay_stdout", :relay)], 0)
      describe_provider(node, "relay_stdout", :relay, [:on_output])
      FakeController.set(node, {Relay, :list_relays}, {:ok, ["relay_a", "relay_b"]})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      html = render_click(view, "plugin_form_provider", %{"provider" => "relay_stdout"})

      assert html =~ ~s(data-testid="input-plugin-relay")
      assert html =~ ~s(<option value="relay_b")
      assert html =~ ~s(data-testid="input-hook-on_output")
      refute html =~ ~s(data-testid="input-plugin-single")
    end

    test "a controller provider asks for no relay, offers its hooks and single", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, %{"default" => {:ok, []}})
      providers(node, [provider("hook_webhook", :controller)], 0)
      describe_provider(node, "hook_webhook", :controller, [:on_relay_started, :on_relay_stopped])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      html = render_click(view, "plugin_form_provider", %{"provider" => "hook_webhook"})

      refute html =~ ~s(data-testid="input-plugin-relay")
      assert html =~ "Controller hooks"
      assert html =~ ~s(data-testid="input-hook-on_relay_started")
      assert html =~ ~s(data-testid="input-plugin-single")

      html =
        render_submit(view, "plugin_form_submit", %{
          "plugin" => %{
            "name" => "hooks_1",
            "hooks" => ["", "on_relay_started", "on_relay_stopped"],
            "single" => "true",
            "opts" => ~s({"url": "http://hooks.test"})
          }
        })

      assert [["hooks_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :enable})
      assert fields[:provider] == "hook_webhook"
      assert fields[:namespace] == "default"
      assert fields[:hooks] == ["on_relay_started", "on_relay_stopped"]
      assert fields[:single] == true
      refute Keyword.has_key?(fields, :relay_id)
      assert html =~ "Plugin hooks_1 enabled."
    end

    test "a controller lacking the provider is named in a warning", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}})
      providers(node, [provider("hook_webhook", :controller)], 0)
      describe_provider(node, "hook_webhook", :controller, [:on_relay_started])

      FakeController.set(
        node,
        {PluginManager, :enable},
        {:ok, %{name: "hooks_1", outcome: :enabled, bound: nil, lacking: [:"flezha@node-b"]}}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      render_click(view, "plugin_form_provider", %{"provider" => "hook_webhook"})

      html = render_submit(view, "plugin_form_submit", %{"plugin" => %{"name" => "hooks_1"}})

      assert html =~
               "Plugin hooks_1 enabled. It does not run on flezha@node-b, which lacks its provider."
    end

    test "every controller holding the provider means no warning", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}})
      providers(node, [provider("hook_webhook", :controller)], 0)
      describe_provider(node, "hook_webhook", :controller, [])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      render_click(view, "plugin_form_provider", %{"provider" => "hook_webhook"})

      html = render_submit(view, "plugin_form_submit", %{"plugin" => %{"name" => "hooks_1"}})

      assert html =~ "Plugin hooks_1 enabled."
      refute html =~ "does not run on"
    end

    test "an enable already done says so", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}})
      providers(node, [provider("hook_webhook", :controller)], 0)
      describe_provider(node, "hook_webhook", :controller, [])

      FakeController.set(
        node,
        {PluginManager, :enable},
        {:ok, %{name: "hooks_1", outcome: :already_enabled, bound: nil, lacking: []}}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      render_click(view, "plugin_form_provider", %{"provider" => "hook_webhook"})

      assert render_submit(view, "plugin_form_submit", %{"plugin" => %{"name" => "hooks_1"}}) =~
               "Plugin hooks_1 was already enabled."
    end

    test "choosing another namespace lists that namespace's relays", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}, "staging" => {:ok, []}})
      providers(node, [provider("relay_stdout", :relay)], 0)
      describe_provider(node, "relay_stdout", :relay, [:on_output])

      FakeController.set(
        node,
        {Relay, :list_relays},
        {:per_arg, 0, %{"staging" => {:ok, ["stage_1"]}}, {:ok, ["relay_a"]}}
      )

      {:ok, view, _html} = live(conn, ~p"/plugins")
      open_enable(view)
      render_click(view, "plugin_form_provider", %{"provider" => "relay_stdout"})

      html = render_change(view, "plugin_form_change", %{"plugin" => %{"namespace" => "staging"}})

      assert html =~ ~s(<option value="stage_1")
      refute html =~ ~s(<option value="relay_a")
    end

    test "the unscoped screen asks which namespace", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}, "staging" => {:ok, []}})
      providers(node, [provider("hook_webhook", :controller)], 0)
      describe_provider(node, "hook_webhook", :controller, [])

      {:ok, view, _html} = live(conn, ~p"/plugins")
      open_enable(view)
      html = render_click(view, "plugin_form_provider", %{"provider" => "hook_webhook"})
      assert html =~ ~s(data-testid="input-plugin-namespace")

      render_submit(view, "plugin_form_submit", %{
        "plugin" => %{"name" => "hooks_1", "namespace" => "staging"}
      })

      assert [["hooks_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :enable})
      assert fields[:namespace] == "staging"
    end
  end

  describe "binding, unbinding and updating" do
    setup %{node: node} do
      with_namespaces(node, %{"default" => {:ok, [plugin("out_1")]}})

      providers(
        node,
        [provider("relay_stdout", :relay), provider("hook_webhook", :controller)],
        0
      )

      describe_provider(node, "relay_stdout", :relay, [:on_output])
      FakeController.set(node, {Relay, :list_relays}, {:ok, ["relay_a", "relay_b"]})
      :ok
    end

    test "binds an enabled plugin to another relay with hooks and a channel", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/plugins")

      html = view |> element(~s([data-testid="plugin-bind-out_1"])) |> render_click()
      assert html =~ "Bind out_1"
      assert html =~ ~s(data-testid="input-plugin-channel")

      html =
        render_submit(view, "plugin_form_submit", %{
          "plugin" => %{"relay_id" => "relay_b", "hooks" => ["", "on_output"], "channel" => "out"}
        })

      assert [["out_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :bind})
      assert fields[:relay_id] == "relay_b"
      assert fields[:hooks] == ["on_output"]
      assert fields[:channel] == "out"
      assert fields[:namespace] == "default"
      assert html =~ "Plugin out_1 bound to relay_b."
    end

    test "a relay already holding the binding is said so", %{conn: conn, node: node} do
      FakeController.set(node, {PluginManager, :bind}, :already_bound)
      {:ok, view, _html} = live(conn, ~p"/plugins")
      view |> element(~s([data-testid="plugin-bind-out_1"])) |> render_click()

      assert render_submit(view, "plugin_form_submit", %{"plugin" => %{"relay_id" => "relay_a"}}) =~
               "relay_a already holds plugin out_1."
    end

    test "a controller plugin is not offered a bind", %{conn: conn, node: node} do
      with_namespaces(node, %{
        "default" =>
          {:ok,
           [
             plugin("hooks_1", %{
               provider: "hook_webhook",
               provider_id: "hook_webhook",
               relays: []
             })
           ]}
      })

      {:ok, _view, html} = live(conn, ~p"/plugins")

      refute html =~ ~s(data-testid="plugin-bind-hooks_1")
      assert html =~ ~s(data-testid="plugin-update-hooks_1")
    end

    test "an unbind asks first, and dismissing it calls nothing", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/plugins")

      html = view |> element(~s([data-testid="plugin-unbind-out_1-relay_a"])) |> render_click()
      assert html =~ ~s(data-testid="plugin-unbind-modal")
      assert html =~ "stays enabled"

      view |> element(~s([data-testid="plugin-unbind-cancel"])) |> render_click()
      assert FakeController.calls(node, {PluginManager, :unbind}) == []
    end

    test "a confirmed unbind keeps the plugin enabled without the relay", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/plugins")
      view |> element(~s([data-testid="plugin-unbind-out_1-relay_a"])) |> render_click()

      with_namespaces(node, %{"default" => {:ok, [plugin("out_1", %{relays: []})]}})
      html = view |> element(~s([data-testid="plugin-unbind-confirm"])) |> render_click()

      assert [["out_1", [namespace: "default", relay_id: "relay_a"], _ctx]] =
               FakeController.calls(node, {PluginManager, :unbind})

      assert html =~ "relay_a unbound from plugin out_1, which stays enabled."
      assert html =~ ~s(data-testid="plugin-row-out_1")
    end

    test "an update reports how it was applied", %{conn: conn, node: node} do
      for {applied, said} <- [
            live: "applied live",
            restarted: "applied by restarting its copies",
            unchanged: "nothing changed"
          ] do
        FakeController.set(
          node,
          {PluginManager, :update},
          {:ok, %{applied: applied, relays: ["relay_a"]}}
        )

        {:ok, view, _html} = live(conn, ~p"/plugins")

        html = view |> element(~s([data-testid="plugin-update-out_1"])) |> render_click()
        assert html =~ "Update out_1"
        assert html =~ "merged into the options the plugin has"
        refute html =~ ~s(data-testid="input-hooks")

        html =
          render_submit(view, "plugin_form_submit", %{
            "plugin" => %{"opts" => ~s({"prefix": "x"})}
          })

        assert html =~ "Plugin out_1 updated: #{said}. Bound to relay_a."
      end

      assert [["out_1", [namespace: "default", opts: %{"prefix" => "x"}], _ctx] | _] =
               FakeController.calls(node, {PluginManager, :update})
    end
  end

  describe "option_specs/2" do
    alias FlezhaUiWeb.Live.PluginForm

    defp kind_of(type, extra \\ %{}) do
      case PluginForm.option_specs(
             [FakeController.option_row("o", Map.put(extra, :type, type))],
             :enable
           ) do
        [%{kind: kind}] -> kind
        [] -> nil
      end
    end

    test "maps each option type to its field kind" do
      assert kind_of(:int) == :int
      assert kind_of(:bool) == :bool
      assert kind_of(:enum, %{values: [:a, :b]}) == :enum
      assert kind_of(:string) == :string
      assert kind_of(:names) == :list
      assert kind_of(:list) == :list
      assert kind_of(:map) == :object
      assert kind_of(:json) == :json
      assert kind_of(:any) == :json
      assert kind_of(:int, %{transient: true}) == :secret
      assert kind_of(:pid) == nil
    end

    test "a type the console does not know is a JSON field, read without an atom" do
      assert kind_of("duration") == :json
      assert kind_of(:keyword) == :json
    end

    test "keeps the controller's order and reads names and declared keys as given" do
      rows = [
        FakeController.option_row(:timeout_ms, %{
          type: :int,
          required: true,
          default: 5000,
          min: 1,
          max: 60_000,
          doc: "Budget"
        }),
        FakeController.option_row("method", %{type: :enum, values: [:get, :put]})
      ]

      assert [
               %{
                 name: "timeout_ms",
                 kind: :int,
                 required: true,
                 default: 5000,
                 min: 1,
                 max: 60_000,
                 doc: "Budget"
               },
               %{name: "method", kind: :enum, values: [:get, :put], required: false, default: nil}
             ] = PluginForm.option_specs(rows, :enable)
    end

    test "on update nothing is required and each hint says how a change is applied" do
      rows = [
        FakeController.option_row("timeout_ms", %{
          type: :int,
          required: true,
          live: true,
          doc: "Budget"
        }),
        FakeController.option_row("url", %{type: :string, required: true})
      ]

      assert [
               %{name: "timeout_ms", required: false, doc: "Budget — changed in place"},
               %{name: "url", required: false, doc: "a change restarts the plugin"}
             ] = PluginForm.option_specs(rows, :update)
    end
  end

  describe "typed options" do
    @rows [
      FakeController.option_row("url", %{type: :string, required: true, doc: "Where to send"}),
      FakeController.option_row("method", %{
        type: :enum,
        values: [:get, :post, :put],
        default: :post
      }),
      FakeController.option_row("timeout_ms", %{
        type: :int,
        min: 1,
        max: 60_000,
        default: 5000,
        live: true,
        doc: "Budget for one request"
      }),
      FakeController.option_row("retries", %{type: :int}),
      FakeController.option_row("inverted", %{type: :bool, default: false}),
      FakeController.option_row("channel", %{type: :names, default: ["a", "b"]}),
      FakeController.option_row("channel_out", %{type: :list, doc: "Names, comma-separated"}),
      FakeController.option_row("headers", %{type: :map, default: %{"x" => "1"}}),
      FakeController.option_row("body", %{type: :json}),
      FakeController.option_row("owner", %{type: :pid}),
      FakeController.option_row("extra", %{type: :any})
    ]

    setup %{node: node} do
      with_namespaces(node, %{
        "default" => {:ok, [plugin("out_1", %{provider_id: "hook_webhook"})]}
      })

      providers(node, [provider("hook_webhook", :controller)], 0)
      describe_provider(node, "hook_webhook", :controller, [:on_relay_started], @rows)
      :ok
    end

    defp choose_webhook(conn) do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      render_click(view, "plugin_form_provider", %{"provider" => "hook_webhook"})
      view
    end

    defp option(name), do: ~s([data-testid="input-option-#{name}"])
    defp option_error(name), do: option(name) <> " ~ .flz-field-error"

    defp enable(view, opts, extra \\ %{}) do
      render_submit(view, "plugin_form_submit", %{
        "plugin" => Map.merge(%{"name" => "hooks_1", "opts" => opts}, extra)
      })
    end

    test "each option is a field of the control its type needs", %{conn: conn} do
      view = choose_webhook(conn)
      html = render(view)

      assert has_element?(view, option("url") <> ~s([type="text"]))
      assert html =~ "url *"
      assert has_element?(view, option("url") <> " ~ .flz-field-hint", "Where to send")

      assert has_element?(
               view,
               option("timeout_ms") <>
                 ~s([type="number"][step="1"][min="1"][max="60000"][placeholder="5000"])
             )

      assert has_element?(
               view,
               option("timeout_ms") <> " ~ .flz-field-hint",
               "Budget for one request"
             )

      assert has_element?(view, ~s(select#{option("method")} option[value="put"]))
      assert has_element?(view, ~s(select#{option("method")} option[value=""]), "default: post")
      assert has_element?(view, ~s(select#{option("inverted")} option[value="true"]))

      assert has_element?(
               view,
               ~s(select#{option("inverted")} option[value=""]),
               "default: false"
             )

      assert has_element?(view, option("channel") <> ~s([type="text"][placeholder="a, b"]))
      assert has_element?(view, option("channel") <> " ~ .flz-field-hint", "comma-separated")

      assert has_element?(
               view,
               option("channel_out") <> " ~ .flz-field-hint",
               ~r/^\s*Names, comma-separated\s*$/
             )

      assert has_element?(view, ~s(textarea#{option("headers")}[placeholder='{"x":"1"}']))
      assert has_element?(view, ~s(textarea#{option("body")}))
      assert has_element?(view, ~s(textarea#{option("extra")}))

      refute has_element?(view, option("owner"))
      refute has_element?(view, ~s([data-testid="input-plugin-opts"]))
      assert has_element?(view, ~s(details[data-testid="provider-help"]))
      refute has_element?(view, ~s(details[data-testid="provider-help"][open]))
    end

    test "enable sends exactly the filled options, typed and keyed by text", %{
      conn: conn,
      node: node
    } do
      view = choose_webhook(conn)

      html =
        enable(view, %{
          "url" => "http://hooks.test",
          "method" => "put",
          "timeout_ms" => "2000",
          "retries" => "",
          "inverted" => "true",
          "channel" => "a, b",
          "headers" => "",
          "body" => ~s({"k": [1]}),
          "extra" => " "
        })

      assert html =~ "Plugin hooks_1 enabled."
      assert [["hooks_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :enable})

      assert fields[:opts] == %{
               "url" => "http://hooks.test",
               "method" => :put,
               "timeout_ms" => 2000,
               "inverted" => true,
               "channel" => ["a", "b"],
               "body" => %{"k" => [1]}
             }
    end

    test "every check that fails is stated on its field and nothing is sent", %{
      conn: conn,
      node: node
    } do
      view = choose_webhook(conn)

      enable(view, %{
        "timeout_ms" => "0",
        "retries" => "1.5",
        "headers" => "[1, 2]",
        "body" => "{"
      })

      assert has_element?(view, option_error("url"), "is required")
      assert has_element?(view, option_error("timeout_ms"), "must be at least 1")
      assert has_element?(view, option_error("retries"), "must be a whole number")
      assert has_element?(view, option_error("headers"), "must be a JSON object")
      assert has_element?(view, option_error("body"), "is not valid JSON")
      refute has_element?(view, ~s([data-testid="attach-error"]))

      enable(view, %{"url" => "http://hooks.test", "timeout_ms" => "60001"})
      assert has_element?(view, option_error("timeout_ms"), "must be at most 60000")
      refute has_element?(view, option_error("url"))

      assert FakeController.calls(node, {PluginManager, :enable}) == []
    end

    test "a refusal naming an option is stated on its field", %{conn: conn, node: node} do
      refuse(node, :enable, "plugin.url_scheme_unsupported", %{
        "provider" => "hook_webhook",
        "option" => "url",
        "url" => "ftp://x"
      })

      view = choose_webhook(conn)
      enable(view, %{"url" => "ftp://x"})

      assert has_element?(
               view,
               option_error("url"),
               "plugin.url_scheme_unsupported (test) (plugin.url_scheme_unsupported)"
             )

      refute has_element?(view, ~s([data-testid="attach-error"]))
      assert has_element?(view, ~s([data-testid="attach-modal"]))
    end

    test "a refusal naming several options is stated on each", %{conn: conn, node: node} do
      refuse(node, :enable, "plugin.options_required", %{
        "provider" => "hook_webhook",
        "options" => [:url, "headers"]
      })

      view = choose_webhook(conn)
      enable(view, %{"url" => "http://hooks.test"})

      assert has_element?(view, option_error("url"), "(plugin.options_required)")
      assert has_element?(view, option_error("headers"), "(plugin.options_required)")
      refute has_element?(view, option_error("body"))
    end

    test "a refusal naming no offered option stays on the form", %{conn: conn, node: node} do
      refuse(node, :enable, "plugin.unknown_options", %{"options" => ["nope"]})

      view = choose_webhook(conn)
      enable(view, %{"url" => "http://hooks.test"})

      assert has_element?(view, ~s([data-testid="attach-error"]), "plugin.unknown_options")
      refute has_element?(view, ".flz-field-error")

      FakeController.set(node, {PluginManager, :enable}, FakeController.error("plugin.id_taken"))
      enable(view, %{"url" => "http://hooks.test"})
      assert has_element?(view, ~s([data-testid="attach-error"]), "plugin.id_taken")
    end

    test "update offers every option, says how each applies and sends only what is filled", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {PluginManager, :update}, {:ok, %{applied: :live, relays: []}})
      {:ok, view, _html} = live(conn, ~p"/plugins")
      html = view |> element(~s([data-testid="plugin-update-out_1"])) |> render_click()

      refute html =~ "url *"

      assert has_element?(
               view,
               option("url") <> " ~ .flz-field-hint",
               "a change restarts the plugin"
             )

      assert has_element?(view, option("timeout_ms") <> " ~ .flz-field-hint", "changed in place")
      assert has_element?(view, option("headers"))

      html =
        render_submit(view, "plugin_form_submit", %{
          "plugin" => %{"opts" => %{"timeout_ms" => "7000", "url" => ""}}
        })

      assert html =~ "Plugin out_1 updated: applied live."
      assert [["out_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :update})
      assert fields[:opts] == %{"timeout_ms" => 7000}
    end

    test "a provider that lists no options is said to take none", %{conn: conn, node: node} do
      describe_provider(node, "hook_webhook", :controller, [], [])
      view = choose_webhook(conn)

      assert has_element?(view, ~s([data-testid="plugin-no-options"]), "takes no options")
      refute has_element?(view, ~s([data-testid="input-plugin-opts"]))

      enable(view, %{})
      assert [["hooks_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :enable})
      assert fields[:opts] == %{}
    end

    test "an update of a provider that takes no options posts nothing and sends none", %{
      conn: conn,
      node: node
    } do
      describe_provider(node, "hook_webhook", :controller, [], [])

      FakeController.set(
        node,
        {PluginManager, :update},
        {:ok, %{applied: :unchanged, relays: []}}
      )

      {:ok, view, _html} = live(conn, ~p"/plugins")
      view |> element(~s([data-testid="plugin-update-out_1"])) |> render_click()

      assert render_submit(view, "plugin_form_submit", %{}) =~
               "Plugin out_1 updated: nothing changed."

      assert [["out_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :update})
      assert fields[:opts] == %{}
    end

    test "a controller that lists no options gets the JSON box, which takes an object", %{
      conn: conn,
      node: node
    } do
      describe_provider(node, "hook_webhook", :controller, [])
      view = choose_webhook(conn)

      assert has_element?(view, ~s([data-testid="input-plugin-opts"]))
      assert has_element?(view, ~s(details[data-testid="provider-help"][open]))
      refute has_element?(view, option("url"))

      html = enable(view, "[1, 2]")
      assert html =~ "Options must be a JSON object."
      assert FakeController.calls(node, {PluginManager, :enable}) == []

      refuse(node, :enable, "plugin.option_invalid", %{"option" => "url"})
      enable(view, ~s({"url": 1}))
      assert has_element?(view, ~s([data-testid="attach-error"]), "plugin.option_invalid")
    end

    test "more options than the form can hold fall back to the JSON box", %{
      conn: conn,
      node: node
    } do
      rows = for i <- 1..129, do: FakeController.option_row("o#{i}", %{type: :string})
      describe_provider(node, "hook_webhook", :controller, [], rows)
      view = choose_webhook(conn)

      assert has_element?(view, ~s([data-testid="input-plugin-opts"]))
      refute has_element?(view, option("o1"))
    end
  end

  describe "secret options" do
    @secret "s3cr3t-never-shown"

    setup %{node: node} do
      with_namespaces(node, %{
        "default" => {:ok, [plugin("out_1", %{provider_id: "hook_webhook"})]}
      })

      providers(node, [provider("hook_webhook", :controller)], 0)

      describe_provider(node, "hook_webhook", :controller, [], [
        FakeController.option_row("url", %{type: :string, required: true}),
        FakeController.option_row("api_key", %{type: :string, transient: true, doc: "The key"})
      ])

      :ok
    end

    defp secret_form(conn) do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      render_click(view, "plugin_form_provider", %{"provider" => "hook_webhook"})
      view
    end

    test "is a password field posted apart from the options", %{conn: conn} do
      view = secret_form(conn)

      assert has_element?(
               view,
               ~s(input[data-testid="input-option-api_key"][type="password"]) <>
                 ~s([autocomplete="new-password"][name="plugin[secret][api_key]"])
             )

      refute has_element?(view, ~s(input[data-testid="input-option-api_key"][placeholder]))
    end

    test "is never rendered back: not after a change, a failed check or a refusal naming it", %{
      conn: conn,
      node: node
    } do
      refuse(
        node,
        :enable,
        "plugin.option_invalid",
        %{"option" => "api_key", "value" => @secret},
        "option 'api_key' does not accept the value #{@secret}"
      )

      view = secret_form(conn)
      secret = %{"api_key" => @secret}

      html = render_change(view, "plugin_form_change", %{"plugin" => %{"secret" => secret}})
      refute html =~ @secret

      html = render_submit(view, "plugin_form_submit", %{"plugin" => %{"secret" => secret}})

      assert has_element?(
               view,
               ~s([data-testid="input-option-url"] ~ .flz-field-error),
               "is required"
             )

      refute html =~ @secret
      assert FakeController.calls(node, {PluginManager, :enable}) == []

      html =
        render_submit(view, "plugin_form_submit", %{
          "plugin" => %{
            "name" => "hooks_1",
            "opts" => %{"url" => "http://h.test"},
            "secret" => secret
          }
        })

      refute html =~ @secret
      refute html =~ "does not accept"

      assert has_element?(
               view,
               ~s([data-testid="input-option-api_key"] ~ .flz-field-error),
               "The controller refused this value (plugin.option_invalid)."
             )

      assert [["hooks_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :enable})
      assert fields[:opts] == %{"url" => "http://h.test", "api_key" => @secret}
    end

    test "an update sends it when filled and leaves it out when blank", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/plugins")

      for {secret, sent} <- [
            {"", %{"url" => "http://h.test"}},
            {@secret, %{"api_key" => @secret}}
          ] do
        view |> element(~s([data-testid="plugin-update-out_1"])) |> render_click()
        opts = if secret == "", do: %{"url" => "http://h.test"}, else: %{}

        render_submit(view, "plugin_form_submit", %{
          "plugin" => %{"opts" => opts, "secret" => %{"api_key" => secret}}
        })

        assert [["out_1", fields, _ctx] | _] =
                 node |> FakeController.calls({PluginManager, :update}) |> Enum.reverse()

        assert fields[:opts] == sent
      end
    end

    test "is filtered from the request and event logs" do
      assert Phoenix.Logger.filter_values(%{"plugin" => %{"secret" => %{"api_key" => "x"}}}) ==
               %{"plugin" => %{"secret" => "[FILTERED]"}}
    end
  end

  describe "where a plugin runs" do
    test "a single plugin, its controllers and the ones that lag are on its row", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, %{
        "default" =>
          {:ok,
           [
             plugin("hooks_1", %{
               provider: "hook_webhook",
               single: true,
               relays: [],
               controllers: [:"flezha@node-a", :"flezha@node-b"],
               hooks: ["on_relay_started"],
               lagging: [:"flezha@node-b"]
             })
           ]}
      })

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ ~s(data-testid="plugin-single-hooks_1")

      assert html =~
               ~r/data-testid="plugin-controllers-hooks_1"[^>]*>\s*flezha@node-a, flezha@node-b/

      assert html =~ ~r/data-testid="plugin-lagging-hooks_1"[^>]*>\s*lagging on flezha@node-b/
    end

    test "nothing lagging shows no lag warning", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, [plugin("out_1")]}})
      {:ok, _view, html} = live(conn, ~p"/plugins")

      refute html =~ "plugin-lagging-out_1"
      refute html =~ "plugin-single-out_1"
    end
  end

  defp refusal(message),
    do:
      Map.from_struct(
        Flezha.Error.new("plugin.package_invalid", message, "flz plugin install --force")
      )

  defp refuse(node, function, code, details, message \\ nil),
    do:
      FakeController.set(
        node,
        {PluginManager, function},
        {:error, Flezha.Error.new(code, message, nil, details)}
      )

  defp provider(id, type), do: %{id: id, module: "Flezha.Plugin.#{id}", type: type}

  defp providers(node, providers, refused),
    do:
      FakeController.set(
        node,
        {Fleet, :providers},
        {:ok, %{providers: providers, refused: refused}}
      )

  # `:absent` answers as a controller that predates the option list.
  defp describe_provider(node, id, type, hooks, options \\ :absent) do
    described = %{provider: id, help: "#{id} options", type: type, hooks: hooks}

    described =
      if options == :absent, do: described, else: Map.put(described, :options, options)

    FakeController.set(node, {Fleet, :provider}, {:ok, described})
  end

  defp open_enable(view),
    do: view |> element(~s([data-testid="enable-plugin-btn"])) |> render_click()
end
