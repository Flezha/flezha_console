defmodule FlezhaUiWeb.PluginLiveTest do
  @moduledoc """
  The plugins screen: every enabled plugin across every operative.

  This screen has no browser coverage at all — it renders a join of the plugin
  registry with each target operative's extension table, and neither half can
  be shaped from a live controller.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.ConfigManager
  alias Flezha.Service.OperativeManager
  alias Flezha.Service.PluginManager

  defp with_plugin(node) do
    FakeController.set(node, {PluginManager, :get_plugins}, %{
      "plug_1" => {"default", "op_a"}
    })

    FakeController.set(
      node,
      {OperativeManager, :get_overwatch_state},
      {:ok,
       %{
         extensions: %{
           subs: %{
             on_input: [%{plugin_id: "plug_1", provider: Flezha.Plugin.OperativeStdout}]
           }
         }
       }}
    )
  end

  describe "listing" do
    test "renders the empty state when nothing is enabled", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/plugins")

      refute html =~ ~s(data-testid="plugin-row-)
    end

    test "joins the registry with the target operative's extension table", %{
      conn: conn,
      node: node
    } do
      with_plugin(node)

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ ~s(data-testid="plugin-row-plug_1")
      assert html =~ "op_a"
      assert html =~ "default"
      # Provider and extension come from the operative, not from the registry.
      assert html =~ "Flezha.Plugin.OperativeStdout"
      assert html =~ "on_input"
    end

    test "a plugin whose operative cannot be read still lists", %{conn: conn, node: node} do
      FakeController.set(node, {PluginManager, :get_plugins}, %{
        "plug_1" => {"default", "op_a"}
      })

      FakeController.set(
        node,
        {OperativeManager, :get_overwatch_state},
        {:error, :operative_not_running}
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      # The registry knows the plugin exists; an unreadable operative must not
      # make it vanish from the list.
      assert html =~ ~s(data-testid="plugin-row-plug_1")
    end

    test "a controller that cannot answer leaves the list empty rather than crashing", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {PluginManager, :get_plugins}, {:error, :timeout})

      {:ok, _view, html} = live(conn, ~p"/plugins")

      refute html =~ ~s(data-testid="plugin-row-)
    end
  end

  describe "available providers" do
    test "lists the providers the controller offers", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {ConfigManager, :get_provider_info},
        {:ok,
         [
           %{id: :operative_stdout, module: "Elixir.Stdout", required_fields: []},
           %{id: :operative_websocket, module: "Elixir.Ws", required_fields: ["uri"]}
         ]}
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      assert html =~ "operative_stdout"
      assert html =~ "operative_websocket"
    end

    test "marks providers an operator cannot configure by hand", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {ConfigManager, :get_provider_info},
        {:ok,
         [
           %{id: :operative_stdout, module: "Elixir.Stdout", required_fields: []},
           # `recv_pid` can only be supplied by code holding a live pid.
           %{id: :internal_listener, module: "Elixir.Listener", required_fields: ["recv_pid"]}
         ]}
      )

      {:ok, _view, html} = live(conn, ~p"/plugins")

      # This screen is a catalog, not a form: an internal provider is listed so
      # an operator knows it exists, and badged so they know why the attach
      # form does not offer it.
      assert html =~ "operative_stdout"
      assert html =~ "internal_listener"
      assert html =~ "Internal"
    end
  end

  describe "disabling a plugin" do
    setup %{node: node} do
      with_plugin(node)
      :ok
    end

    test "is confirm-gated, and cancelling reaches nothing", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/plugins")

      render_click(view, "confirm_disable", %{"plugin_id" => "plug_1"})
      render_click(view, "cancel_disable", %{})

      assert FakeController.calls(node, {Flezha, :disable_plugin}) == []
    end

    test "confirming reaches the controller and reports it", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/plugins")
      render_click(view, "confirm_disable", %{"plugin_id" => "plug_1"})

      assert render_click(view, "disable_plugin", %{"plugin_id" => "plug_1"}) =~
               "Plugin plug_1 disabled."

      assert FakeController.calls(node, {Flezha, :disable_plugin}) == [["plug_1"]]
    end

    test "a refusal is reported rather than shown as success", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :disable_plugin}, {:error, :not_found})

      {:ok, view, _html} = live(conn, ~p"/plugins")
      render_click(view, "confirm_disable", %{"plugin_id" => "plug_1"})

      assert render_click(view, "disable_plugin", %{"plugin_id" => "plug_1"}) =~
               "Failed: :not_found"
    end
  end
end
