defmodule FlezhaConsoleWeb.PluginLiveTest do
  @moduledoc """
  The plugins screen: the plugins enabled in each reachable namespace, the
  relays bound to each, the providers on offer and the installed packages.

  A refused namespace and an unavailable installer are states a live
  controller will not be put into on demand, which is why they are produced
  here.
  """

  use FlezhaConsoleWeb.LiveCase

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
    FakeController.set(node, {Relay, :list_namespaces}, FakeController.rows(catalog))

    FakeController.set(
      node,
      {PluginManager, :enabled},
      {:per_arg, 0, plugins_by_namespace, {:ok, []}}
    )
  end

  describe "listing" do
    test "lists each enabled plugin with provider, namespace, relays and hooks", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, %{"default" => {:ok, [plugin("plug_1")]}})
      describe_provider(node, "relay_stdout", :relay, [:on_output])

      {:ok, view, _html} = live(conn, ~p"/plugins")

      row = view |> element(~s([data-testid="plugin-row-plug_1"])) |> render()
      assert row =~ ~s(data-testid="plugin-menu-plug_1")

      assert view |> element(~s([data-testid="plugin-description-plug_1"])) |> render() =~
               "relay_stdout options"

      assert row =~ "Relay Stdout"
      assert row =~ "default"
      assert row =~ "relay_a"
      assert row =~ "on_output"
    end

    test "a plugin opens in the inspector with its provider's help", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, [plugin("plug_1")]}})
      describe_provider(node, "relay_stdout", :relay, [:on_output])

      {:ok, view, _html} = live(conn, ~p"/plugins")
      view |> element(~s([data-testid="plugin-inspect-plug_1"])) |> render_click()
      html = render(view)

      assert html =~ ~s(data-testid="inspector-plugin")

      assert view |> element(~s(pre[data-testid="inspector-provider-help"])) |> render() =~
               "relay_stdout options"
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
             |> Enum.all?(&match?(["staging", _page, _ctx], &1))
    end
  end

  describe "available providers" do
    test "lists the providers the controller offers, by id", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :providers},
        {:ok,
         %{
           rows: [
             %{id: "relay_stdout", module: "Flezha.Plugin.Provider.StdOut", type: :relay},
             %{id: "relay_websocket", module: "Flezha.Plugin.Provider.Websocket", type: :relay}
           ],
           refused: %{"flezha@node-a": 0},
           unreachable: []
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/plugins")
      html = open_section(view, "providers")

      assert html =~ ~s(data-testid="providers-panel")
      assert html =~ ~s(data-testid="provider-relay_stdout")
      assert html =~ ~s(data-testid="provider-relay_websocket")

      assert view |> element(~s([data-testid="provider-module-relay_stdout"])) |> render() =~
               "Flezha.Plugin.Provider.StdOut"
    end

    test "a refused provider listing is stated", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :providers},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/plugins")
      html = open_section(view, "providers")

      assert html =~ "authz.role_insufficient"
    end
  end

  describe "disabling a plugin" do
    setup %{node: node} do
      with_namespaces(node, %{"default" => {:ok, [plugin("plug_1")]}})
      :ok
    end

    test "confirming disables it by name in its namespace", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/plugins")

      assert disable(view, "plug_1") =~
               "Plugin plug_1 disabled."

      assert [["plug_1", %{"namespace" => "default"}, %{token: _}]] =
               FakeController.calls(node, {PluginManager, :disable})
    end

    test "a plugin the controller does not know is reported as such", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {PluginManager, :disable},
        FakeController.error("plugin.not_found")
      )

      {:ok, view, _html} = live(conn, ~p"/plugins")

      assert disable(view, "plug_1") =~
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
        FakeController.rows([
          %{id: "kafka", version: "1.2.0", status: :loaded, error: nil},
          %{
            id: "s3",
            version: "0.9.0",
            status: :refused,
            providers: ["file_s3"],
            error: refusal("digest mismatch")
          }
        ])
      )

      {:ok, view, html} = live(conn, ~p"/plugins")

      assert html =~ ~s(data-testid="installed-kafka")
      assert html =~ "1.2.0"
      assert view |> element(~s([data-testid="installed-status-s3"])) |> render() =~ "Refused"
      assert html =~ "digest mismatch"
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
        FakeController.rows([
          %{id: "http", version: "1.0.0", status: :loaded, providers: ["http_push"], error: nil},
          %{
            id: "s3",
            version: "0.9.0",
            status: :refused,
            providers: ["file_s3"],
            error: refusal("bad manifest")
          }
        ])
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert text_of(html, ~s([data-testid="installed-providers-http"])) == "http_push"

      error = text_of(html, ~s([data-testid="installed-error-s3"]))
      assert error =~ "plugin.package_invalid"
      assert error =~ "bad manifest"
      assert error =~ "flz plugin install --force"
    end

    # The controller lists only the providers of packages it loaded.
    test "the enable form offers the providers the controller lists", %{conn: conn, node: node} do
      providers(node, [provider("relay_stdout", :relay)], 1)
      {:ok, view, _html} = live(conn, ~p"/plugins")

      html = open_enable(view)

      assert html =~ ~s(data-testid="plugin-steps")
      assert html =~ ~s(data-testid="provider-btn-relay_stdout")
      assert length(Regex.scan(~r/data-testid="provider-btn-/, html)) == 1
    end

    test "a pending package shows the version still loaded", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :installed_plugins},
        FakeController.rows([
          %{
            id: "http",
            version: "1.1.0",
            status: :pending,
            loaded_version: "1.0.0",
            providers: [],
            error: nil
          }
        ])
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert text_of(html, ~s([data-testid="installed-loaded-http"])) =~ "1.0.0 still loaded"
    end

    test "the provider listing states how many packages were refused", %{conn: conn, node: node} do
      providers(node, [provider("relay_stdout", :relay)], 2)

      {:ok, view, _html} = live(conn, ~p"/plugins")
      html = open_section(view, "providers")

      assert html =~ ~s(data-testid="providers-refused")
      assert html =~ "The controller refused 2 installed packages at boot"
    end
  end

  describe "packages and providers on several controllers" do
    test "copies that agree are one row naming every controller holding them", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Fleet, :installed_plugins},
        FakeController.rows([
          %{id: "http", version: "1.0.0", status: :loaded, node: :flezha@c1, error: nil},
          %{id: "http", version: "1.0.0", status: :loaded, node: :flezha@c2, error: nil}
        ])
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert length(Regex.scan(~r/data-testid="installed-http"/, html)) == 1
      assert text_of(html, ~s([data-testid="installed-nodes-http"])) =~ ~r/c1\s+c2/
    end

    test "copies that differ are a row each, each naming its controller", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Fleet, :installed_plugins},
        FakeController.rows([
          %{id: "http", version: "1.0.0", status: :loaded, node: :flezha@c1, error: nil},
          %{id: "http", version: "1.1.0", status: :pending, node: :flezha@c2, error: nil}
        ])
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert length(Regex.scan(~r/data-testid="installed-http"/, html)) == 2
      assert html =~ ~s(title="flezha@c1")
      assert html =~ ~s(title="flezha@c2")
    end

    test "a provider one controller cannot enable says where it is not offered", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Fleet, :providers},
        {:ok,
         %{
           rows: [
             Map.put(provider("relay_stdout", :relay), :nodes, [:flezha@c1, :flezha@c2]),
             Map.put(provider("relay_kafka", :relay), :nodes, [:flezha@c1])
           ],
           refused: %{flezha@c1: 0, flezha@c2: 1},
           unreachable: []
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/plugins")
      html = open_section(view, "providers")

      assert text_of(html, ~s([data-testid="provider-lacking-relay_kafka"])) =~
               ~r/Not offered on\s+c2/

      refute html =~ ~s(data-testid="provider-lacking-relay_stdout")
      assert text_of(html, ~s([data-testid="providers-refused"])) =~ "flezha@c2 refused 1 package"
    end

    test "each controller refusing as many packages is said once", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :providers},
        {:ok, %{rows: [], refused: %{flezha@c1: 1, flezha@c2: 1}, unreachable: []}}
      )

      {:ok, view, _html} = live(conn, ~p"/plugins")
      html = open_section(view, "providers")

      assert text_of(html, ~s([data-testid="providers-refused"])) =~
               "Each controller refused 1 installed package at boot"
    end
  end

  describe "enabling a plugin" do
    test "a relay provider asks for a relay and offers its relay hooks", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}})
      providers(node, [provider("relay_stdout", :relay)], 0)
      describe_provider(node, "relay_stdout", :relay, [:on_output])

      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows(Enum.map(["relay_a", "relay_b"], &FakeController.relay_row/1))
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      html = choose(view, "relay_stdout")

      assert html =~ ~s(data-testid="input-plugin-relay")
      assert html =~ ~s(data-testid="input-plugin-relay-relay_b")
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
      html = choose(view, "hook_webhook")

      refute html =~ ~s(data-testid="input-plugin-relay")
      assert html =~ "Controller hooks"
      assert html =~ ~s(data-testid="input-hook-on_relay_started")
      assert html =~ ~s(data-testid="input-plugin-single")

      html =
        submit_plugin_form(view, %{
          "name" => "hooks_1",
          "hooks" => ["", "on_relay_started", "on_relay_stopped"],
          "single" => "true",
          "opts" => ~s({"url": "http://hooks.test"})
        })

      assert [["hooks_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :enable})
      assert fields["provider"] == "hook_webhook"
      assert fields["namespace"] == "default"
      assert fields["hooks"] == ["on_relay_started", "on_relay_stopped"]
      assert fields["single"] == true
      refute Map.has_key?(fields, "relay_id")
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
      choose(view, "hook_webhook")

      html = submit_plugin_form(view, %{"name" => "hooks_1"})

      assert html =~
               "Plugin hooks_1 enabled. It does not run on flezha@node-b, which lacks its provider."
    end

    test "every controller holding the provider means no warning", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}})
      providers(node, [provider("hook_webhook", :controller)], 0)
      describe_provider(node, "hook_webhook", :controller, [])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      choose(view, "hook_webhook")

      html = submit_plugin_form(view, %{"name" => "hooks_1"})

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
      choose(view, "hook_webhook")

      assert submit_plugin_form(view, %{"name" => "hooks_1"}) =~
               "Plugin hooks_1 was already enabled."
    end

    test "choosing another namespace lists that namespace's relays", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}, "staging" => {:ok, []}})
      providers(node, [provider("relay_stdout", :relay)], 0)
      describe_provider(node, "relay_stdout", :relay, [:on_output])

      FakeController.set(
        node,
        {Relay, :list},
        {:per_arg, 0, %{"staging" => FakeController.rows([FakeController.relay_row("stage_1")])},
         FakeController.rows([FakeController.relay_row("relay_a")])}
      )

      {:ok, view, _html} = live(conn, ~p"/plugins")
      open_enable(view)
      choose(view, "relay_stdout")
      to_step(view, 1)

      html = change(view, %{"namespace" => "staging"})

      assert html =~ ~s(data-testid="input-plugin-relay-stage_1")
      refute html =~ ~s(data-testid="input-plugin-relay-relay_a")
    end

    test "the unscoped screen asks which namespace", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}, "staging" => {:ok, []}})
      providers(node, [provider("hook_webhook", :controller)], 0)
      describe_provider(node, "hook_webhook", :controller, [])

      {:ok, view, _html} = live(conn, ~p"/plugins")
      open_enable(view)
      html = choose(view, "hook_webhook")
      assert html =~ ~s(data-testid="input-plugin-namespace")

      submit_plugin_form(view, %{"name" => "hooks_1", "namespace" => "staging"})

      assert [["hooks_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :enable})
      assert fields["namespace"] == "staging"
    end
  end

  describe "the enable flow" do
    test "providers are grouped by what they do, and the chosen one is described before the form",
         %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}})

      providers(
        node,
        [
          Map.put(provider("relay_file_input", :relay), :feeds, true),
          provider("relay_stdout", :relay),
          provider("hook_webhook", :controller)
        ],
        0
      )

      describe_provider(node, "relay_stdout", :relay, [:on_output], [
        FakeController.option_row("prefix", %{type: :string, required: true, doc: "Put first"})
      ])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      html = open_enable(view)

      assert text_of(html, ~s([data-testid="provider-grid"])) =~
               ~r/Sources\s*Relay File Input.*Taps and sinks\s*Relay Stdout.*Controller plugins\s*Hook Webhook/

      html = view |> element(~s([data-testid="provider-role-controller"])) |> render_click()
      assert html =~ ~s(data-testid="provider-btn-hook_webhook")
      refute html =~ ~s(data-testid="provider-btn-relay_stdout")

      view |> element(~s([data-testid="provider-role-all"])) |> render_click()
      html = choose(view, "relay_stdout")

      detail = text_of(html, ~s([data-testid="provider-detail"]))
      assert detail =~ "Taps and sinks"
      assert detail =~ "runs on a relay"
      assert detail =~ "1 required of 1"
      assert detail =~ "on_output"
      assert detail =~ ~r/prefix\s*Put first/
      assert text_of(html, ~s([data-testid="plugin-steps-step-0"])) =~ "Relay Stdout"
      assert has_element?(view, ~s([data-testid="plugin-placement"][hidden]))

      view |> element(~s([data-testid="attach-next-btn"])) |> render_click()
      refute has_element?(view, ~s([data-testid="plugin-placement"][hidden]))

      assert has_element?(
               view,
               ~s([data-testid="input-hook-on_output"] ~ span),
               "Each record the relay puts out"
             )
    end

    test "each step is checked before the next opens, and a done step goes back", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, %{"default" => {:ok, []}})
      providers(node, [provider("hook_webhook", :controller)], 0)

      describe_provider(node, "hook_webhook", :controller, [:on_relay_started], [
        FakeController.option_row("url", %{type: :string, required: true})
      ])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      choose(view, "hook_webhook")
      view |> element(~s([data-testid="attach-next-btn"])) |> render_click()

      named = fn -> view |> element(~s([data-testid="input-plugin-name"])) |> render() end
      before = named.()
      view |> element(~s([data-testid="plugin-rename-btn"])) |> render_click()
      assert named.() != before

      at = fn n -> has_element?(view, ~s([data-testid="plugin-steps"][data-step="#{n}"])) end

      html = step(view, %{name: " "})
      assert text_of(html, ~s([data-testid="attach-error"])) =~ "A plugin name is required."
      assert at.(1)

      html = step(view, %{name: "hooks_1", hooks: ["", "on_relay_started"]})
      assert at.(2)
      assert text_of(html, ~s([data-testid="plugin-steps-step-1"])) =~ "hooks_1 in default"

      step(view, %{opts: %{url: ""}})
      assert has_element?(view, ~s([data-testid="input-option-url"] ~ .fcon-error), "is required")
      assert at.(2)

      html = step(view, %{opts: %{url: "http://h.test"}})
      assert at.(3)

      assert text_of(html, ~s([data-testid="plugin-review"])) =~
               "Enable Hook Webhook as hooks_1 in default."

      view |> element(~s([data-testid="plugin-steps-go-1"])) |> render_click()
      assert at.(1)
      step(view, %{})
      html = step(view, %{})

      assert text_of(html, ~s([data-testid="plugin-command"])) ==
               "flz plugin enable hooks_1 hook_webhook --namespace default " <>
                 "--hook=on_relay_started --Xurl=http://h.test"

      assert FakeController.calls(node, {PluginManager, :enable}) == []
    end

    test "a step's field sent again from another step keeps what its own step chose", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, %{"default" => {:ok, []}})
      providers(node, [provider("relay_stdout", :relay)], 0)
      describe_provider(node, "relay_stdout", :relay, [:on_output], [])

      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows(Enum.map(["relay_a"], &FakeController.relay_row/1))
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      choose(view, "relay_stdout")
      to_step(view, 1)

      step(view, %{name: "out_1", relay_id: "relay_a", hooks: ["", "on_output"]})
      html = step(view, %{name: "other", relay_id: "", hooks: [""]})

      assert text_of(html, ~s([data-testid="review-relay"])) == "relay_a"
      assert text_of(html, ~s([data-testid="review-hooks"])) == "on_output"
      assert text_of(html, ~s([data-testid="plugin-review"])) =~ "Enable Relay Stdout as out_1"
    end

    test "another provider drops what was typed for the last", %{conn: conn, node: node} do
      with_namespaces(node, %{"default" => {:ok, []}})

      providers(
        node,
        [provider("relay_stdout", :relay), provider("hook_webhook", :controller)],
        0
      )

      FakeController.set(
        node,
        {Fleet, :provider},
        {:per_arg, 0,
         %{
           "relay_stdout" =>
             {:ok, %{provider: "relay_stdout", help: nil, type: :relay, hooks: [], options: []}}
         },
         {:ok,
          %{
            provider: "hook_webhook",
            help: nil,
            type: :controller,
            hooks: [],
            options: [FakeController.option_row("url", %{type: :string})]
          }}}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")
      open_enable(view)
      choose(view, "hook_webhook")
      to_step(view, 2)
      change(view, %{"opts" => %{"url" => "http://typed.test"}})
      assert has_element?(view, ~s([data-testid="input-option-url"][value="http://typed.test"]))

      to_step(view, 0)
      choose(view, "relay_stdout")
      choose(view, "hook_webhook")
      refute has_element?(view, ~s([data-testid="input-option-url"][value="http://typed.test"]))
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

      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows(Enum.map(["relay_a", "relay_b"], &FakeController.relay_row/1))
      )

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
        submit_plugin_form(view, %{
          "relay_id" => "relay_b",
          "hooks" => ["", "on_output"],
          "channel" => "out"
        })

      assert [["out_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :bind})
      assert fields["relay_id"] == "relay_b"
      assert fields["hooks"] == ["on_output"]
      assert fields["channel"] == "out"
      assert fields["namespace"] == "default"
      assert html =~ "Plugin out_1 bound to relay_b."
    end

    test "a bind starts from the plugin's own hooks", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/plugins")
      view |> element(~s([data-testid="plugin-bind-out_1"])) |> render_click()

      assert has_element?(view, ~s([data-testid="input-hook-on_output"][checked]))
      submit_plugin_form(view, %{"relay_id" => "relay_b"})

      assert [["out_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :bind})
      assert fields["hooks"] == ["on_output"]
    end

    test "a provider's Enable opens the flow on its placement", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/plugins")
      open_section(view, "providers")
      view |> element(~s([data-testid="provider-enable-relay_stdout"])) |> render_click()

      assert text_of(render(view), ~s([data-testid="plugin-steps-step-0"])) =~ "Relay Stdout"
      refute has_element?(view, ~s([data-testid="plugin-placement"][hidden]))
    end

    test "a relay already holding the binding is said so", %{conn: conn, node: node} do
      FakeController.set(node, {PluginManager, :bind}, :already_bound)
      {:ok, view, _html} = live(conn, ~p"/plugins")
      view |> element(~s([data-testid="plugin-bind-out_1"])) |> render_click()

      assert submit_plugin_form(view, %{"relay_id" => "relay_a"}) =~
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

    test "a confirmed unbind keeps the plugin enabled without the relay", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/plugins")
      view |> element(~s([data-testid="plugin-unbind-out_1-relay_a"])) |> render_click()

      with_namespaces(node, %{"default" => {:ok, [plugin("out_1", %{relays: []})]}})
      html = view |> element(~s([data-testid="plugin-unbind-confirm"])) |> render_click()

      assert [["out_1", %{"namespace" => "default", "relay_id" => "relay_a"}, _ctx]] =
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

        html = submit_plugin_form(view, %{"opts" => ~s({"prefix": "x"})})

        assert html =~ "Plugin out_1 updated: #{said}. Bound to relay_a."
      end

      assert [["out_1", %{"namespace" => "default", "opts" => %{"prefix" => "x"}}, _ctx] | _] =
               FakeController.calls(node, {PluginManager, :update})
    end
  end

  describe "option_specs/2" do
    alias FlezhaConsoleWeb.Live.PluginForm

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
      choose(view, "hook_webhook")
      view
    end

    defp option(name), do: ~s([data-testid="input-option-#{name}"])
    defp option_error(name), do: option(name) <> " ~ .fcon-error"

    defp enable(view, opts), do: submit_plugin_form(view, %{"name" => "hooks_1", "opts" => opts})

    test "each option is a field of the control its type needs", %{conn: conn} do
      view = choose_webhook(conn)
      html = render(view)

      assert has_element?(view, option("url") <> ~s([type="text"]))
      assert html =~ "url *"
      assert has_element?(view, option("url") <> " ~ .fcon-hint", "Where to send")

      assert has_element?(
               view,
               option("timeout_ms") <>
                 ~s([type="number"][step="1"][min="1"][max="60000"][placeholder="5000"])
             )

      assert has_element?(
               view,
               option("timeout_ms") <> " ~ .fcon-hint",
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
      assert has_element?(view, option("channel") <> " ~ .fcon-hint", "comma-separated")

      assert has_element?(
               view,
               option("channel_out") <> " ~ .fcon-hint",
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

    test "the optional options stay folded until unfolded, and open when one is refused", %{
      conn: conn
    } do
      view = choose_webhook(conn)
      folded = ~s([data-testid="plugin-optional-toggle"][aria-expanded="false"])

      assert has_element?(view, folded)
      assert has_element?(view, ~s(#plugin-optional[hidden] ) <> option("timeout_ms"))

      view |> element(~s([data-testid="plugin-optional-toggle"])) |> render_click()
      refute has_element?(view, ~s(#plugin-optional[hidden]))
      view |> element(~s([data-testid="plugin-optional-toggle"])) |> render_click()
      assert has_element?(view, folded)

      enable(view, %{"url" => "http://hooks.test", "timeout_ms" => "0"})
      assert has_element?(view, option_error("timeout_ms"), "must be at least 1")
      refute has_element?(view, ~s(#plugin-optional[hidden]))
    end

    test "a number in a unit its name spells is read back at a glance", %{conn: conn} do
      view = choose_webhook(conn)
      hint = option("timeout_ms") <> " ~ .fcon-hint"

      assert has_element?(view, hint, "Budget for one request · default 5s")

      to_step(view, 2)
      change(view, %{"opts" => %{"timeout_ms" => "90000"}})
      assert has_element?(view, hint, "Budget for one request · = 1m 30s")
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

      assert fields["opts"] == %{
               "url" => "http://hooks.test",
               "method" => "put",
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
      refute has_element?(view, ".fcon-error")

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
               option("url") <> " ~ .fcon-hint",
               "a change restarts the plugin"
             )

      assert has_element?(view, option("timeout_ms") <> " ~ .fcon-hint", "changed in place")
      assert has_element?(view, option("headers"))

      html = submit_plugin_form(view, %{"opts" => %{"timeout_ms" => "7000", "url" => ""}})

      assert html =~ "Plugin out_1 updated: applied live."
      assert [["out_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :update})
      assert fields["opts"] == %{"timeout_ms" => 7000}
    end

    test "a provider that lists no options is said to take none", %{conn: conn, node: node} do
      describe_provider(node, "hook_webhook", :controller, [], [])
      view = choose_webhook(conn)

      assert has_element?(view, ~s([data-testid="plugin-no-options"]), "takes no options")
      refute has_element?(view, ~s([data-testid="input-plugin-opts"]))

      enable(view, %{})
      assert [["hooks_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :enable})
      assert fields["opts"] == %{}
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

      assert submit_plugin_form(view, %{}) =~
               "Plugin out_1 updated: nothing changed."

      assert [["out_1", fields, _ctx]] = FakeController.calls(node, {PluginManager, :update})
      assert fields["opts"] == %{}
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
      choose(view, "hook_webhook")
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

      to_step(view, 2)
      html = change(view, %{"secret" => secret})
      refute html =~ @secret

      html = submit_plugin_form(view, %{"secret" => secret})

      assert has_element?(
               view,
               ~s([data-testid="input-option-url"] ~ .fcon-error),
               "is required"
             )

      refute html =~ @secret
      assert FakeController.calls(node, {PluginManager, :enable}) == []

      html =
        submit_plugin_form(view, %{
          "opts" => %{"url" => "http://h.test"},
          "secret" => secret
        })

      refute html =~ @secret
      refute html =~ "does not accept"

      assert has_element?(
               view,
               ~s([data-testid="input-option-api_key"] ~ .fcon-error),
               "The controller refused this value (plugin.option_invalid)."
             )

      assert [[_name, fields, _ctx]] = FakeController.calls(node, {PluginManager, :enable})
      assert fields["opts"] == %{"url" => "http://h.test", "api_key" => @secret}
    end

    test "is read from the environment in the review's command, never written in it", %{
      conn: conn
    } do
      view = secret_form(conn)

      fields = %{
        "name" => "hooks_1",
        "opts" => %{"url" => "http://h.test/x?y=1"},
        "secret" => %{"api_key" => @secret}
      }

      html = Enum.reduce(1..3, nil, fn _step, _html -> step(view, fields) end)

      assert text_of(html, ~s([data-testid="plugin-command"])) ==
               ~s(flz plugin enable hooks_1 hook_webhook --namespace default --Xapi_key="$API_KEY" --Xurl='http://h.test/x?y=1')

      assert text_of(html, ~s([data-testid="review-options"])) =~ ~r/api_key\s*set, not shown/
      refute html =~ @secret
    end

    test "an update sends it when filled and leaves it out when blank", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/plugins")

      for {secret, sent} <- [
            {"", %{"url" => "http://h.test"}},
            {@secret, %{"api_key" => @secret}}
          ] do
        view |> element(~s([data-testid="plugin-update-out_1"])) |> render_click()
        opts = if secret == "", do: %{"url" => "http://h.test"}, else: %{}

        submit_plugin_form(view, %{"opts" => opts, "secret" => %{"api_key" => secret}})

        assert [["out_1", fields, _ctx] | _] =
                 node |> FakeController.calls({PluginManager, :update}) |> Enum.reverse()

        assert fields["opts"] == sent
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

      assert html =~ ~r/data-testid="plugin-lagging-hooks_1"[^>]*>\s*Lagging on flezha@node-b/
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
        {:ok, %{rows: providers, refused: %{"flezha@node-a": refused}, unreachable: []}}
      )

  # `:absent` answers as a controller that predates the option list.
  defp describe_provider(node, id, type, hooks, options \\ :absent) do
    described = %{provider: id, help: "#{id} options", type: type, hooks: hooks}

    described =
      if options == :absent, do: described, else: Map.put(described, :options, options)

    FakeController.set(node, {Fleet, :provider}, {:ok, described})
  end

  defp choose(view, provider),
    do: view |> element(~s([data-testid="provider-btn-#{provider}"])) |> render_click()

  # One submit of the plugin form, which on an enable moves on one step.
  defp step(view, fields) do
    {typed, picked} = plugin_fields(fields)

    view
    |> form(~s([data-testid="plugin-form"]), plugin: typed)
    |> render_submit(%{plugin: picked})
  end

  # Moves the open enable flow to `step`: back at once, forward a step at a
  # time, as the rail and Next do.
  defp to_step(view, 0), do: render_click(view, "plugin_form_step", %{"step" => "0"})

  defp to_step(view, step),
    do: for(s <- 1..step, do: render_click(view, "plugin_form_step", %{"step" => "#{s}"}))

  defp change(view, fields) do
    {typed, picked} = plugin_fields(fields)

    view
    |> form(~s(form[phx-change="plugin_form_change"]), plugin: typed)
    |> render_change(%{plugin: picked})
  end

  defp disable(view, name) do
    view |> element(~s([data-testid="plugin-disable-#{name}"])) |> render_click()
    view |> element(~s([data-testid="plugin-disable-confirm"])) |> render_click()
  end

  defp open_enable(view),
    do: view |> element(~s([data-testid="enable-plugin-btn"])) |> render_click()
end
