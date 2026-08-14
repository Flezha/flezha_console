defmodule FlezhaUiWeb.ScheduleLive do
  @moduledoc """
  Cron schedules: the persisted entries joined with their live job status.

  An entry can exist in the store without being armed on the hub — after a hub
  restart, say — so the two are shown together rather than the store alone
  implying the job is running.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    socket =
      socket
      |> assign(
        page_title: "Schedules",
        show_form: false,
        form: empty_form(),
        form_error: nil,
        confirm_remove: nil
      )
      |> refresh()

    {:ok, socket}
  end

  # Holding still while a modal is open keeps a row from moving underneath the
  # operator between reading it and confirming.
  @impl FlezhaUiWeb.Live.Refresh
  def refresh_paused?(socket),
    do: socket.assigns.show_form or socket.assigns.confirm_remove != nil

  @impl true
  def handle_event("open_form", _params, socket) do
    {:noreply, assign(socket, show_form: true, form: empty_form(), form_error: nil)}
  end

  @impl true
  def handle_event("close_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, form_error: nil)}
  end

  @impl true
  def handle_event("form_change", %{"schedule" => params}, socket) do
    {:noreply, assign(socket, form: Map.merge(socket.assigns.form, params))}
  end

  @impl true
  def handle_event("create", %{"schedule" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)

    with :ok <- require_fields(form),
         {:ok, fields} <- entry_fields(form),
         {:ok, entry} <- NodeManager.schedule_add(fields) do
      # Persist first, then arm: an entry the hub refuses is still recoverable
      # from the store, whereas an armed job with nothing persisted is not.
      _ = NodeManager.schedule_assert(entry)

      {:noreply,
       socket
       |> assign(show_form: false, form_error: nil)
       |> put_flash(:info, "Schedule #{form["name"]} created.")
       |> refresh()}
    else
      {:error, reason} -> {:noreply, assign(socket, form_error: schedule_error(reason))}
    end
  end

  @impl true
  def handle_event("confirm_remove", %{"name" => name}, socket) do
    {:noreply, assign(socket, confirm_remove: name)}
  end

  @impl true
  def handle_event("cancel_remove", _params, socket) do
    {:noreply, assign(socket, confirm_remove: nil)}
  end

  @impl true
  def handle_event("remove", %{"name" => name}, socket) do
    # Retract before deleting: a job left armed against a deleted entry would
    # keep firing with nothing describing it.
    _ = NodeManager.schedule_retract(name)

    case NodeManager.schedule_remove(name) do
      :ok ->
        {:noreply,
         socket
         |> assign(confirm_remove: nil)
         |> put_flash(:info, "Schedule #{name} removed.")
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_remove: nil)
         |> put_flash(:error, schedule_error(reason))}
    end
  end

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    case NodeManager.schedule_list() do
      {:ok, entries} ->
        statuses = status_index(NodeManager.schedule_statuses())

        assign(socket,
          schedules: Enum.map(entries, &decorate(&1, statuses)),
          load_error: nil
        )

      {:error, reason} ->
        assign(socket, schedules: [], load_error: reason)
    end
  end

  defp status_index(statuses) when is_list(statuses) do
    Map.new(statuses, fn status ->
      {to_string(status[:name] || status["name"]), status}
    end)
  end

  defp status_index(statuses) when is_map(statuses) do
    Map.new(statuses, fn {name, status} -> {to_string(name), status} end)
  end

  defp status_index(_), do: %{}

  defp decorate(entry, statuses) do
    name = to_string(Map.get(entry, :name) || Map.get(entry, "name"))
    cron = Map.get(entry, :cron) || Map.get(entry, "cron")
    timezone = Map.get(entry, :timezone) || Map.get(entry, "timezone")
    status = Map.get(statuses, name)

    %{
      name: name,
      cron: cron,
      timezone: timezone,
      # A schedule spawns an operative from a factory, so its target is the
      # namespace and factory it will spawn into.
      namespace: Map.get(entry, :namespace) || Map.get(entry, "namespace") || "—",
      factory_id: Map.get(entry, :factory_id) || Map.get(entry, "factory_id") || "—",
      # A persisted entry with no hub status is not armed; saying so is more
      # useful than a blank cell that reads as "unknown".
      armed: status != nil,
      node: status && Map.get(status, :node),
      last_fire: status && Map.get(status, :last_fire),
      next_fire: next_fire(cron, timezone)
    }
  end

  defp next_fire(cron, timezone) when is_binary(cron) and is_binary(timezone) do
    case NodeManager.schedule_next_fire(cron, timezone) do
      %DateTime{} = dt -> dt
      {:ok, %DateTime{} = dt} -> dt
      _ -> nil
    end
  end

  defp next_fire(_cron, _timezone), do: nil

  defp empty_form do
    %{
      "name" => "",
      "cron" => "",
      "timezone" => "Etc/UTC",
      "namespace" => "default",
      "factory_id" => "",
      "init_values" => ""
    }
  end

  defp require_fields(form) do
    missing =
      ~w(name cron namespace factory_id)
      |> Enum.filter(fn field -> String.trim(form[field] || "") == "" end)

    if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
  end

  defp entry_fields(form) do
    with {:ok, init_values} <- parse_init_values(form["init_values"]) do
      {:ok,
       %{
         name: String.trim(form["name"]),
         cron: String.trim(form["cron"]),
         timezone: blank_default(form["timezone"], "Etc/UTC"),
         namespace: blank_default(form["namespace"], "default"),
         factory_id: String.trim(form["factory_id"]),
         init_values: init_values
       }}
    end
  end

  defp parse_init_values(value) do
    case String.trim(value || "") do
      "" -> {:ok, %{}}
      json -> with {:error, _} <- Jason.decode(json), do: {:error, :invalid_init_values}
    end
  end

  defp blank_default(value, default) do
    case String.trim(value || "") do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp schedule_error({:missing_fields, fields}) do
    labels = Enum.map_join(fields, ", ", &(&1 |> String.replace("_", " ") |> String.capitalize()))
    "Required: #{labels}."
  end

  defp schedule_error(:invalid_init_values), do: "Init Values must be valid JSON."
  defp schedule_error({:invalid_cron, detail}), do: "Invalid cron expression: #{detail}"
  defp schedule_error({:invalid_timezone, tz}), do: "Unknown timezone: #{tz}"
  defp schedule_error({:invalid_name, detail}), do: "Invalid name: #{detail}"
  defp schedule_error({:invalid_factory, detail}), do: "Invalid factory: #{detail}"
  defp schedule_error({:invalid_init_values, detail}), do: "Invalid init values: #{detail}"
  defp schedule_error(:already_exists), do: "A schedule with that name already exists."
  defp schedule_error(reason), do: "Schedule error: #{inspect(reason)}"
end
