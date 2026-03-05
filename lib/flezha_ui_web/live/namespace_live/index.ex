defmodule FlezhaUiWeb.NamespaceLive.Index do
  use FlezhaUiWeb, :live_view

  alias FlezhaUi.Service.NodeManager

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)
    {:ok, assign(socket, namespaces: load_namespaces(), page_title: "Namespaces")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, assign(socket, namespaces: load_namespaces())}
  end

  defp load_namespaces do
    case NodeManager.list_namespaces() do
      list when is_list(list) ->
        Enum.map(list, fn ns ->
          proc_count =
            case NodeManager.list_processors(ns) do
              {:ok, list} -> length(list)
              _ -> 0
            end

          ce_count =
            case NodeManager.list_compute_engines(ns) do
              {:ok, list} -> length(list)
              _ -> 0
            end

          %{name: ns, processor_count: proc_count, ce_count: ce_count}
        end)

      _ ->
        []
    end
  end
end
