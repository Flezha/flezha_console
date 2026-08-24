defmodule FlezhaUiWeb.NamespaceLive.Index do
  @moduledoc """
  Namespaces as objects, not merely as running hubs.

  `Flezha.list_namespaces/0` answers hubs that are up. A namespace is also a
  declared record with quotas and role bindings, and the two sets do not have
  to agree: a namespace can be declared with nothing running, and a hub can be
  running for a namespace nobody declared. Both are listed, and each row says
  which it is.
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
       create_form: %{"name" => "", "max_operatives" => "", "max_runners" => ""},
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

    if name == "" do
      {:noreply, assign(socket, create_error: "A namespace name is required.")}
    else
      case NodeManager.create_namespace(
             name,
             quota_overrides(params),
             socket.assigns.flezha_token
           ) do
        {:ok, _entry} ->
          {:noreply,
           socket
           |> assign(show_create: false, create_error: nil)
           |> refresh()
           |> put_flash(:info, "Namespace #{name} declared.")}

        {:error, reason} ->
          {:noreply, assign(socket, create_error: refusal(reason))}
      end
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
      case NodeManager.delete_namespace(name) do
        {:error, reason} ->
          {:noreply,
           socket
           |> assign(confirm_delete: nil, delete_confirmation: "")
           |> put_flash(:error, "Delete failed: #{refusal(reason)}")}

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
    {declared, unavailable?} = declared_namespaces()

    case NodeManager.list_namespaces() do
      {:ok, running} ->
        assign(socket,
          namespaces: rows(declared, running, socket.assigns.flezha_token),
          declarations_unavailable?: unavailable?,
          load_error: nil
        )

      {:error, reason} ->
        assign(socket,
          namespaces: [],
          declarations_unavailable?: unavailable?,
          load_error: reason
        )
    end
  end

  # A controller predating declared namespaces still runs hubs, so the listing
  # falls back to those and says the declarations are what is missing.
  defp declared_namespaces do
    case NodeManager.declared_namespaces() do
      {:ok, entries} -> {entries, false}
      {:error, {:api_missing, _module, _function, _arity}} -> {[], true}
      {:error, _reason} -> {[], true}
    end
  end

  defp rows(declared, running, token) do
    scope = NodeManager.token_scope(token)
    running = NodeManager.scope_namespaces(running, scope) |> Enum.map(&to_string/1)
    by_name = Map.new(declared, &{to_string(&1.name), &1})

    declared
    |> NodeManager.known_namespace_names(running, scope)
    |> Enum.map(fn name ->
      entry = Map.get(by_name, name)
      running? = name in running

      %{
        name: name,
        declared?: entry != nil,
        running?: running?,
        quotas: entry && entry.quotas,
        # A declared namespace with no hub has nothing running in it, which is
        # zero rather than unknown.
        operative_count: if(running?, do: count(NodeManager.operative_rows(name)), else: 0),
        runner_count: if(running?, do: count(NodeManager.list_runners(name)), else: 0),
        breaches: breaches(name, entry)
      }
    end)
  end

  # Only a declared namespace has limits to breach; an undeclared one has
  # counters but nothing to measure them against.
  defp breaches(_name, nil), do: []

  defp breaches(name, entry) do
    name |> NodeManager.quota_usage(entry.quotas) |> Enum.filter(& &1.breached?)
  end

  defp count(result), do: result |> NodeManager.ok_or([]) |> length()

  defp quota_overrides(params) do
    ~w(max_operatives max_runners)a
    |> Enum.reduce(%{}, fn key, acc ->
      case Integer.parse(String.trim(params[to_string(key)] || "")) do
        {value, ""} -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp refusal({:forbidden, reason}), do: FlezhaUiWeb.CoreComponents.forbidden_reason(reason)
  defp refusal(reason), do: inspect(reason)
end
