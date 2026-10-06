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
        provider: "relay_stdout",
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
      assert row =~ "relay_stdout"
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
           %{id: "s3", version: "0.9.0", status: :refused, error: %{message: "digest mismatch"}}
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
end
