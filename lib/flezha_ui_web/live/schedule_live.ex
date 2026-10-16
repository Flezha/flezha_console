defmodule FlezhaUiWeb.ScheduleLive do
  @moduledoc """
  Cron schedules: the persisted entries joined with their live job status.

  An entry can exist in the store without being armed on the hub — after a hub
  restart, say — so the two are shown together rather than the store alone
  implying the job is running.

  The same screen serves one namespace at `/namespaces/:ns/schedules`. The
  controller keeps one schedule registry for the cluster and answers it whole,
  so the scope is a filter over the namespace each entry already carries; the
  screen says so, and the creation form opens aimed at that namespace.

  Only a steps factory can be scheduled, so the form offers only those.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Live.Target

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> start_refresh()
      |> assign(
        page_title: "Schedules",
        show_form: false,
        form: empty_form(nil),
        form_error: nil,
        confirm_remove: nil,
        target: Target.new(nil),
        schedules: [],
        loaded?: false,
        load_error: nil,
        confirm_run: nil,
        ran: nil
      )

    {:ok, socket}
  end

  # `?run=<name>` lands the command palette's "run now" on this screen's own
  # confirmation: a schedule is never fired by a keystroke alone.
  @impl true
  def handle_params(params, _uri, socket) do
    title = Layouts.scoped_title("Schedules", socket.assigns.scoped_namespace)
    socket = socket |> assign(page_title: title) |> refresh_when_connected()

    case params["run"] do
      name when is_binary(name) and name != "" ->
        socket =
          if NodeManager.granted?(socket.assigns.operations, "Schedule.run"),
            do: assign(socket, confirm_run: name),
            else: socket

        # Once applied, `run` leaves the address, so a reload does not ask again.
        if connected?(socket),
          do:
            {:noreply,
             push_patch(socket, to: Map.get(socket.assigns, :current_path, ~p"/schedules"))},
          else: {:noreply, socket}

      _none ->
        {:noreply, socket}
    end
  end

  # Holding still while a modal is open keeps a row from moving underneath the
  # operator between reading it and confirming.
  @impl FlezhaUiWeb.Live.Refresh
  def refresh_paused?(socket),
    do:
      socket.assigns.show_form or socket.assigns.confirm_remove != nil or
        socket.assigns.confirm_run != nil

  # The target is listed here rather than on the tick: a schedule list that
  # re-read a catalog per namespace every five seconds would pay for a form that
  # is almost always closed.
  @impl true
  def handle_event("open_form", _params, socket) do
    form = empty_form(socket.assigns.scoped_namespace)
    target = Target.load_namespaces(Target.new(socket.assigns.flezha_token, run: :steps))
    namespace = Target.namespace(target, form["namespace"])

    socket =
      socket
      |> assign(show_form: true, form_error: nil, target: target)
      |> assign(form: Map.put(form, "namespace", namespace))
      |> aim(namespace)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, form_error: nil)}
  end

  @impl true
  def handle_event("form_change", %{"schedule" => params}, socket) do
    was = socket.assigns.form["namespace"]
    form = Map.merge(socket.assigns.form, params)
    socket = assign(socket, form: form)

    if form["namespace"] == was do
      {:noreply, socket}
    else
      {:noreply, aim(socket, form["namespace"])}
    end
  end

  @impl true
  def handle_event("create", %{"schedule" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)

    with :ok <- require_fields(form),
         {:ok, fields} <- entry_fields(form),
         {:ok, _added} <- NodeManager.schedule_add(fields, socket.assigns.flezha_token) do
      {:noreply,
       socket
       |> assign(show_form: false, form_error: nil)
       |> put_flash(:info, "Schedule #{form["name"]} created.")
       |> refresh()}
    else
      {:error, reason} -> {:noreply, assign(socket, form_error: schedule_error(reason))}
    end
  end

  # Fires the schedule once, whatever its cron says and whether or not the
  # schedule hub is up. What it answered stays above the listing until the
  # next run replaces it.
  @impl true
  def handle_event("confirm_run", %{"name" => name}, socket) do
    {:noreply, assign(socket, confirm_run: name)}
  end

  @impl true
  def handle_event("cancel_run", _params, socket) do
    {:noreply, assign(socket, confirm_run: nil)}
  end

  @impl true
  # Only the open confirmation fires, and only once: a second click finds it
  # already closed.
  def handle_event("run_now", %{"name" => name}, %{assigns: %{confirm_run: name}} = socket) do
    socket = assign(socket, confirm_run: nil)
    schedule = Enum.find(socket.assigns.schedules, %{}, &(&1.name == name))

    ran =
      case NodeManager.schedule_run(name, socket.assigns.flezha_token) do
        {:ok, answer} -> %{name: name, namespace: Map.get(schedule, :namespace), answer: answer}
        {:error, reason} -> %{name: name, error: reason}
      end

    {:noreply, socket |> assign(ran: ran) |> refresh()}
  end

  def handle_event("run_now", _params, socket), do: {:noreply, socket}

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
    case NodeManager.schedule_remove(name, socket.assigns.flezha_token) do
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
    case NodeManager.schedule_list(socket.assigns.flezha_token) do
      {:ok, entries} ->
        assign(socket,
          loaded?: true,
          schedules: rows(entries, socket.assigns.scoped_namespace),
          load_error: nil
        )

      {:error, reason} ->
        assign(socket, schedules: [], load_error: reason, loaded?: true)
    end
  end

  @doc """
  The schedules `NodeManager.schedule_list/1` answered, as the console shows
  them, narrowed to `namespace` when there is one.
  """
  def rows(entries, namespace) do
    entries |> Enum.map(&decorate/1) |> NodeManager.in_namespace(namespace)
  end

  # The controller joins each stored entry with what the schedule hub holds
  # for it. A stored entry no node fires is not armed; saying so is more useful
  # than a blank cell that reads as "unknown".
  defp decorate(entry) do
    %{
      name: to_string(entry.name),
      cron: entry.cron,
      timezone: entry.timezone,
      # A schedule starts a relay from a factory, so its target is the
      # namespace and factory it will start into.
      namespace: Map.get(entry, :namespace) || "—",
      factory_id: Map.get(entry, :factory_id) || "—",
      armed: Map.get(entry, :node) != nil,
      node: Map.get(entry, :node),
      last_fire: last_fire(Map.get(entry, :last_fire)),
      next_fire: next_fire(Map.get(entry, :next_fire))
    }
  end

  @doc "What a schedule's status means, for its badge's tooltip."
  def status_title(true),
    do: "A node holds this schedule and fires it on time; the last fire shows how that went."

  def status_title(false),
    do:
      "No node holds this schedule right now, so it does not fire: the schedule hub may be down or still taking it."

  @doc "How far the create form has got, for its steps."
  def form_step(form) do
    cond do
      blank?(form["name"]) or blank?(form["cron"]) -> 0
      blank?(form["namespace"]) or blank?(form["factory_id"]) -> 1
      true -> 2
    end
  end

  defp blank?(value), do: String.trim(value || "") == ""

  defp next_fire(%DateTime{} = dt), do: dt
  defp next_fire({:ok, %DateTime{} = dt}), do: dt
  defp next_fire(_none), do: nil

  # The hub reports a fire as the started instance, its outcome and when it ran.
  defp last_fire(%{at: %DateTime{} = at}), do: at
  defp last_fire(_none), do: nil

  defp aim(socket, namespace) do
    {target, form} = Target.aim(socket.assigns.target, namespace, socket.assigns.form)

    assign(socket, target: target, form: form)
  end

  defp empty_form(scope) do
    %{
      "name" => "",
      "cron" => "",
      "timezone" => "Etc/UTC",
      "namespace" => scope || "default",
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
    with {:ok, init_values} <- NodeManager.parse_init_values(form["init_values"]) do
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

  # `NodeManager.parse_init_values/1` already answers what to put on the form.
  defp schedule_error(message) when is_binary(message), do: message

  defp schedule_error(reason),
    do: error_message(reason, "the schedule")
end
