defmodule FlezhaUiWeb.Live.Launcher do
  @moduledoc """
  Starting an operative — the one write this panel exists to make easy.

  It is reachable from two screens that ask different questions: a namespace's
  detail page, where the namespace is already decided, and the cross-namespace
  operatives index, where it is not. Both get the same form, the same
  validation and the same call, because a write path implemented twice drifts
  and the half that drifts is the one nobody is looking at.

      use FlezhaUiWeb.Live.Refresh, every: 5_000
      use FlezhaUiWeb.Live.Launcher

      def mount(_params, _session, socket) do
        {:ok, socket |> start_refresh() |> launcher_init(nil) |> refresh()}
      end

  `launcher_init/2` takes the namespace to start into, or `nil` for a screen
  that has to ask. A screen that asks answers `launcher_namespaces/1` with the
  listing it already holds, so offering the choice costs it no second read. The
  host renders `launcher_dialog/1` and points a control at the `launcher_open`
  event; everything else — the four events, the catalog read, the kind probe —
  is injected.

  The kinds are probed once on arrival and again on each open, so a screen with
  a kind filter can offer exactly what the form offers by reading
  `@launcher.kinds`. The namespace and factory listings ride
  `FlezhaUiWeb.Live.Target`, which the schedule form aims the same way.

  The screen holds still while the form is open, as every other modal on these
  screens does, and leaves `refresh_paused?/1` overridable for a host with
  dialogs of its own.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Live.Target

  # Named exactly rather than by prefix, and namespaced, so a host's own events
  # cannot be swallowed by the injected clause.
  @events ~w(launcher_open launcher_close launcher_change launcher_submit)

  @doc """
  The namespaces this screen can start into, as `scoped_namespaces/1` answers
  them.

  A screen that pinned its namespace needs none; one that asks answers with the
  listing it already loaded rather than reading it again.
  """
  @callback launcher_namespaces(Phoenix.LiveView.Socket.t()) :: {[String.t()], term()}

  @doc false
  defmacro __using__(_opts) do
    events = @events

    quote do
      @behaviour FlezhaUiWeb.Live.Launcher

      import FlezhaUiWeb.Live.Launcher, only: [launcher_init: 2, launcher_dialog: 1]

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) when event in unquote(events) do
        {:noreply, FlezhaUiWeb.Live.Launcher.handle_event(__MODULE__, event, params, socket)}
      end

      @impl FlezhaUiWeb.Live.Launcher
      def launcher_namespaces(_socket), do: {[], nil}

      @impl FlezhaUiWeb.Live.Refresh
      def refresh_paused?(socket), do: FlezhaUiWeb.Live.Launcher.open?(socket)

      defoverridable launcher_namespaces: 1, refresh_paused?: 1
    end
  end

  # ---- Host seam ----

  @doc """
  Initial assigns for a host embedding the launcher. Call before the first load.

  `namespace` pins the field to that namespace; `nil` renders a namespace
  selector fed from `launcher_namespaces/1`.
  """
  def launcher_init(socket, namespace) do
    assign(socket,
      launcher: %{
        open?: false,
        fixed_namespace: namespace,
        form: empty_form(namespace),
        target: Target.new(),
        kinds: NodeManager.known_kinds(),
        error: nil
      }
    )
  end

  @doc "True while the form is open — the state a host ORs into its own pause."
  def open?(socket), do: socket.assigns[:launcher][:open?] == true

  defp empty_form(namespace) do
    %{
      "namespace" => namespace || "",
      "id" => "",
      "factory_id" => "",
      "kind" => "stream",
      "init_values" => "",
      "snapshot_interval" => ""
    }
  end

  # ---- Events ----

  @doc false
  def handle_event(module, "launcher_open", _params, socket) do
    target = Target.put_namespaces(Target.new(), module.launcher_namespaces(socket))
    namespace = socket.assigns.launcher.fixed_namespace || Target.namespace(target)

    state = %{
      socket.assigns.launcher
      | open?: true,
        form: empty_form(namespace),
        target: target,
        kinds: NodeManager.known_kinds(),
        error: nil
    }

    put_launcher(socket, aim(state, namespace))
  end

  def handle_event(_module, "launcher_close", _params, socket) do
    update_launcher(socket, &%{&1 | open?: false, error: nil})
  end

  def handle_event(_module, "launcher_change", %{"start" => params}, socket) do
    state = socket.assigns.launcher
    form = Map.merge(state.form, params)

    # The catalog is a per-namespace read, so it is re-listed exactly when the
    # namespace moves — never on a keystroke in another field, and never on a
    # refresh tick.
    if form["namespace"] == state.form["namespace"] do
      put_launcher(socket, %{state | form: form})
    else
      put_launcher(socket, aim(%{state | form: form}, form["namespace"]))
    end
  end

  def handle_event(module, "launcher_submit", %{"start" => params}, socket) do
    state = socket.assigns.launcher
    form = Map.merge(state.form, params)
    socket = put_launcher(socket, %{state | form: form})

    case start(state, form) do
      {:ok, namespace, id} ->
        socket
        |> update_launcher(&%{&1 | open?: false, error: nil})
        |> then(&module.refresh/1)
        |> Phoenix.LiveView.put_flash(:info, started_message(state, namespace, id))

      {:error, message} ->
        update_launcher(socket, &%{&1 | error: message})
    end
  end

  # The namespace screen already names its namespace in the heading, so the
  # flash that repeats it there would be noise; the index cannot say which
  # namespace it went to any other way.
  defp started_message(%{fixed_namespace: nil}, namespace, id),
    do: "Operative #{id} started in #{namespace}."

  defp started_message(_state, _namespace, id), do: "Operative #{id} started."

  defp start(state, form) do
    namespace = String.trim(form["namespace"] || "")
    id = String.trim(form["id"] || "")
    factory_id = String.trim(form["factory_id"] || "")

    with :ok <- require_namespace(namespace),
         :ok <- require_factories(state.target),
         :ok <- require_id_and_factory(id, factory_id),
         {:ok, kind} <- resolve_kind(state.kinds, form["kind"]),
         {:ok, init_values} <- NodeManager.parse_init_values(form["init_values"]),
         opts <- build_opts(form) do
      case NodeManager.start_operative(namespace, id, factory_id, init_values, opts, kind) do
        {:error, reason} -> {:error, inspect(reason)}
        _started -> {:ok, namespace, id}
      end
    end
  end

  defp require_namespace(""), do: {:error, "A namespace is required."}
  defp require_namespace(_namespace), do: :ok

  # Only when the listing succeeded and was empty: a namespace whose catalog
  # could not be read still accepts a typed factory id.
  defp require_factories(target) do
    if Target.no_factories?(target),
      do: {:error, "#{Target.no_factories_message()}."},
      else: :ok
  end

  defp require_id_and_factory("", _factory_id), do: {:error, "ID and Factory ID are required."}
  defp require_id_and_factory(_id, ""), do: {:error, "ID and Factory ID are required."}
  defp require_id_and_factory(_id, _factory_id), do: :ok

  # Resolved against the kinds the controller recognises rather than by
  # `String.to_atom/1`: a form field must not be able to mint atoms, and a kind
  # the controller does not know would be refused anyway.
  defp resolve_kind(kinds, value) do
    value = to_string(value || "")

    case Enum.find(kinds, &(to_string(&1.kind) == value)) do
      %{kind: kind} -> {:ok, kind}
      nil -> {:error, "Kind must be one of: #{kind_names(kinds)}."}
    end
  end

  defp kind_names(kinds), do: Enum.map_join(kinds, ", ", &to_string(&1.kind))

  defp build_opts(form) do
    case Integer.parse(String.trim(form["snapshot_interval"] || "")) do
      {interval, ""} -> [snapshot_interval: interval]
      _not_an_interval -> []
    end
  end

  # ---- Catalog ----

  defp aim(state, namespace) do
    {target, form} = Target.aim(state.target, namespace, state.form)

    %{state | target: target, form: form}
  end

  defp put_launcher(socket, state), do: assign(socket, launcher: state)

  defp update_launcher(socket, fun),
    do: put_launcher(socket, fun.(socket.assigns.launcher))

  # ---- Rendering ----

  @doc "The start form, as a modal."
  attr :launcher, :map, required: true

  def launcher_dialog(assigns) do
    ~H"""
    <.dialog :if={@launcher.open?} testid="start-modal" size="form" on_close="launcher_close">
      <:title>Start Operative</:title>

      <.notice :if={@launcher.error} kind={:error} testid="start-error" class="mb-4">
        {@launcher.error}
      </.notice>

      <form phx-submit="launcher_submit" phx-change="launcher_change" class="space-y-4">
        <%!-- A screen that pinned its namespace does not ask again; the form
              keeps it, so there is nothing to submit either. --%>
        <Target.namespace_field
          :if={is_nil(@launcher.fixed_namespace)}
          target={@launcher.target}
          name="start[namespace]"
          label="Namespace *"
          value={@launcher.form["namespace"]}
          testid="input-namespace"
        />

        <.input
          type="text"
          name="start[id]"
          label="Operative ID *"
          value={@launcher.form["id"]}
          placeholder="my-operative"
          maxlength="32"
          data-testid="input-operative-id"
        />

        <Target.factory_field
          target={@launcher.target}
          name="start[factory_id]"
          label="Factory ID *"
          value={@launcher.form["factory_id"]}
          testid="input-factory-id"
        />

        <.input
          type="select"
          name="start[kind]"
          label="Kind *"
          value={@launcher.form["kind"]}
          options={kind_options(@launcher.kinds)}
          hint={kind_hint(@launcher.kinds, @launcher.form["kind"])}
          data-testid="input-kind"
        />

        <.input
          type="textarea"
          name="start[init_values]"
          label="Init Values"
          hint="JSON, optional"
          value={@launcher.form["init_values"]}
          placeholder="{}"
          mono
          data-testid="input-init-values"
        />

        <.input
          type="number"
          name="start[snapshot_interval]"
          label="Snapshot Interval"
          value={@launcher.form["snapshot_interval"]}
          placeholder="optional"
          data-testid="input-snapshot-interval"
        />

        <div class="flex justify-end gap-3 pt-2">
          <.button variant="ghost" phx-click="launcher_close" data-testid="start-cancel-btn">
            Cancel
          </.button>
          <.button
            type="submit"
            data-testid="start-submit-btn"
            disabled={Target.no_factories?(@launcher.target)}
          >
            Start
          </.button>
        </div>
      </form>
    </.dialog>
    """
  end

  defp kind_options(kinds), do: Enum.map(kinds, &{to_string(&1.kind), to_string(&1.kind)})

  defp kind_hint(kinds, chosen) do
    case Enum.find(kinds, &(to_string(&1.kind) == chosen)) do
      %{capabilities: []} -> "Declares no capabilities — no persistent entity state."
      %{capabilities: capabilities} -> "Capabilities: #{Enum.join(capabilities, ", ")}."
      nil -> nil
    end
  end
end
