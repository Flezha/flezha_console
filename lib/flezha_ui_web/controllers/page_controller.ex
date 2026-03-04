defmodule FlezhaUiWeb.PageController do
  use FlezhaUiWeb, :controller

  def home(conn, _params) do
    namespaces =
      case FlezhaUi.Service.NodeManager.erpc_call(Flezha, :list_namespaces, []) do
        {:ok, namespaces} -> namespaces
        {:error, _reason} -> []
      end

    conn =
      conn
      |> assign(:namespaces, namespaces)

    render(conn, :home, layout: false)
  end
end
