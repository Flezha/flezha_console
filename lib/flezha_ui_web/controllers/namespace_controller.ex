defmodule FlezhaUiWeb.NamespaceController do
  use FlezhaUiWeb, :controller

  def show(conn, %{"namespace_id" => namespace_id}) do
    processors =
      case FlezhaUi.Service.NodeManager.erpc_call(Flezha, :list_processors, [namespace_id]) do
        {:ok, processors} -> processors
        {:error, _reason} -> []
      end

    compute_engines =
      case FlezhaUi.Service.NodeManager.erpc_call(Flezha, :list_compute_engines, [namespace_id]) do
        {:ok, compute_engines} -> compute_engines
        {:error, _reason} -> []
      end

    namespace_dataset = %{
      id: namespace_id,
      processors: processors,
      compute_engines: compute_engines
    }

    conn =
      conn
      |> assign(:namespace, namespace_dataset)

    render(conn, :show)
  end
end
