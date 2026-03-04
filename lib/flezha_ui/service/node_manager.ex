defmodule FlezhaUi.Service.NodeManager do
  def connected_node do
    # This function should return the first connected node
    # or nil if no nodes are connected.
    Node.list(:hidden) |> List.first()
  end

  def erpc_call(module, function, args) do
    node = connected_node()

    if is_atom(node) do
      case :erpc.call(node, module, function, args) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :node_not_connected}
    end
  end
end
