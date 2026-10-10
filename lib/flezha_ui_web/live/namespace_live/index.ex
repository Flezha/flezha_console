defmodule FlezhaUiWeb.NamespaceLive.Index do
  @moduledoc """
  Namespaces as objects, not merely as running hubs.

  The controller's catalog answers every namespace the caller may see with
  whether a hub runs for it, so a namespace declared with nothing running is
  listed too, and each row says which it is. The declarations — quotas and who
  created them — are read beside it.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> assign(
       page_title: "Namespaces",
       declarations_unavailable?: false,
       show_create: false,
       create_form: %{"name" => "", "max_relays" => "", "max_runners" => ""},
       create_error: nil,
       confirm_delete: nil,
       delete_confirmation: ""
     )
     |> refresh()}
  end

  @impl true
  def handle_event("open_create", _params, socket) do
    {:noreply, assign(socket, show_create: true, create_error: nil)}
  end

  @impl true
  def handle_event("close_create", _params, socket) do
    {:noreply, assign(socket, show_create: false)}
  end

  @impl true
  def handle_event("create_change", %{"create" => params}, socket) do
    {:noreply, assign(socket, create_form: Map.merge(socket.assigns.create_form, params))}
  end

  @impl true
  def handle_event("create", %{"create" => params}, socket) do
    name = String.trim(params["name"] || "")

    with :ok <- if(name == "", do: {:error, "A namespace name is required."}, else: :ok),
         {:ok, limits} <- NodeManager.parse_limits(params, ~w(max_relays max_runners)a),
         {:ok, _entry} <- NodeManager.create_namespace(name, limits, socket.assigns.flezha_token) do
      {:noreply,
       socket
       |> assign(show_create: false, create_error: nil)
       |> refresh()
       |> put_flash(:info, "Namespace #{name} declared.")}
    else
      {:error, reason} -> {:noreply, assign(socket, create_error: reason)}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"name" => name}, socket) do
    {:noreply, assign(socket, confirm_delete: name, delete_confirmation: "")}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: nil, delete_confirmation: "")}
  end

  @impl true
  def handle_event("delete_confirmation_change", %{"confirm" => %{"name" => value}}, socket) do
    {:noreply, assign(socket, delete_confirmation: value)}
  end

  @impl true
  def handle_event("delete", _params, socket) do
    name = socket.assigns.confirm_delete

    # The typed name is a confirmation, never an argument: the namespace acted
    # on is the one the operator opened the dialog for.
    if socket.assigns.delete_confirmation == name do
      case NodeManager.delete_namespace(name, socket.assigns.flezha_token) do
        {:error, reason} ->
          {:noreply,
           socket
           |> assign(confirm_delete: nil, delete_confirmation: "")
           |> put_flash(:error, error_message(reason, "the delete"))}

        _ok ->
          {:noreply,
           socket
           |> assign(confirm_delete: nil, delete_confirmation: "")
           |> refresh()
           |> put_flash(:info, "Namespace #{name} deleted.")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token

    case NodeManager.list_namespaces(token) do
      {:ok, catalog} ->
        {records, unavailable?} = records(token)

        assign(socket,
          namespaces: Enum.map(catalog, &row(&1, records, token)),
          declarations_unavailable?: unavailable?,
          load_error: nil
        )

      {:error, reason} ->
        assign(socket, namespaces: [], declarations_unavailable?: false, load_error: reason)
    end
  end

  # A controller that cannot answer the records still lists its namespaces,
  # and the screen says the declarations are what is missing.
  defp records(token) do
    case NodeManager.namespace_records(token) do
      {:ok, records} -> {Map.new(records, &{to_string(&1.name), &1}), false}
      {:error, _reason} -> {%{}, true}
    end
  end

  defp row(%{namespace: name, running: running?}, records, token) do
    name = to_string(name)
    record = Map.get(records, name)

    %{
      name: name,
      declared?: record != nil,
      running?: running?,
      quotas: record && record.quotas,
      # A namespace with no hub has nothing running in it, which is zero
      # rather than unknown.
      relay_count: if(running?, do: count(NodeManager.list_relays(name, token)), else: 0),
      runner_count: if(running?, do: count(NodeManager.runners(name, token)), else: 0),
      breaches: breaches(name, record, token)
    }
  end

  # Only a declared namespace has limits to breach; an undeclared one has
  # counters but nothing to measure them against.
  defp breaches(_name, nil, _token), do: []

  defp breaches(name, record, token) do
    name |> NodeManager.quota_usage(record.quotas, token) |> Enum.filter(& &1.breached?)
  end

  defp count(result), do: result |> NodeManager.ok_or([]) |> length()
end
