defmodule FlezhaUiWeb.NamespaceLive.Index do
  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> start_refresh() |> assign(page_title: "Namespaces") |> refresh()}
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    case list_namespaces() do
      {:ok, namespaces} -> assign(socket, namespaces: namespaces, load_error: nil)
      {:error, reason} -> assign(socket, namespaces: [], load_error: reason)
    end
  end

  defp list_namespaces do
    case NodeManager.list_namespaces() do
      {:ok, list} ->
        {:ok,
         Enum.map(list, fn ns ->
           %{
             name: ns,
             operative_count: count(NodeManager.list_operatives(ns)),
             runner_count: count(NodeManager.list_runners(ns))
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count({:ok, list}), do: length(list)
  defp count({:error, _reason}), do: 0
end
