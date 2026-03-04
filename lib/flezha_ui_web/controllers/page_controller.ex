defmodule FlezhaUiWeb.PageController do
  use FlezhaUiWeb, :controller

  def home(conn, _params) do
    FlezhaUi.Service.NodeManager.erpc_call(Flezha, :list_groups, []) |> dbg()

    groups =
      case FlezhaUi.Service.NodeManager.erpc_call(Flezha, :list_groups, []) do
        {:ok, groups} -> groups
        {:error, _reason} -> []
      end

    conn =
      conn
      |> assign(:groups, groups)

    render(conn, :home, layout: false)
  end
end
