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

  defp provider(id, type), do: %{id: id, module: "Flezha.Plugin.#{id}", type: type}

  defp providers(node, providers, refused),
    do:
      FakeController.set(
        node,
        {Fleet, :providers},
        {:ok, %{providers: providers, refused: refused}}
      )

  defp describe_provider(node, id, type, hooks) do
    FakeController.set(
      node,
      {Fleet, :provider},
      {:ok, %{provider: id, help: "#{id} options", type: type, hooks: hooks}}
    )
  end

  defp open_enable(view),
    do: view |> element(~s([data-testid="enable-plugin-btn"])) |> render_click()
end
