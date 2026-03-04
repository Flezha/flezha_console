defmodule FlezhaUiWeb.OperatorGroupController do
  use FlezhaUiWeb, :controller

  def show(conn, %{"group_id" => group_id}) do
    operators =
      case FlezhaUi.Service.NodeManager.erpc_call(Flezha, :list_operators, [group_id]) do
        {:ok, operators} -> operators
        {:error, _reason} -> []
      end

    group_dataset = %{
      id: group_id,
      operators: operators
    }

    conn =
      conn
      |> assign(:group, group_dataset)

    render(conn, :show)
  end
end
