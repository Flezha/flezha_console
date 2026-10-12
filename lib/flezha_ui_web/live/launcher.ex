defmodule FlezhaUiWeb.Live.Launcher do
  @moduledoc """
  Starting a relay — the one write this panel exists to make easy.

  It is reachable from two screens that ask different questions: a namespace's
  detail page, where the namespace is already decided, and the cross-namespace
  relays index, where it is not. Both get the same form, the same validation
  and the same call, because a write path implemented twice drifts and the half
  that drifts is the one nobody is looking at.

      use FlezhaUiWeb.Live.Refresh, every: 5_000
      use FlezhaUiWeb.Live.Launcher

      def mount(_params, _session, socket) do
        {:ok, socket |> start_refresh() |> launcher_init(nil) |> refresh()}
      end

  `launcher_init/2` takes the namespace to start into, or `nil` for a screen
  that has to ask. A screen that asks answers `launcher_namespaces/1` with the
  listing it already holds, so offering the choice costs it no second read. The
  host renders `launcher_dialog/1` and points a control at the `launcher_open`
  event; everything else — the four events and the catalog read — is injected.

  It is a guided flow of three steps: Factory (searchable, each with its
  description, its run and how many runners serve it, an unserved one shown
  unavailable with that reason), Details (the optional id and the init values),
  and Review (one sentence saying what will start, then Start). How a relay
  runs is its factory's, so the flow asks for none. The namespace and factory
  listings ride `FlezhaUiWeb.Live.Target`, which the schedule form aims the
  same way.

  The screen holds still while the form is open, as every other modal on these
  screens does, and leaves `refresh_paused?/1` overridable for a host with
  dialogs of its own.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Live.Target

  # Named exactly rather than by prefix, and namespaced, so a host's own events
  # cannot be swallowed by the injected clause.
  @events ~w(launcher_open launcher_close launcher_change launcher_pick launcher_next
             launcher_back launcher_submit)

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
        step: 0,
        fixed_namespace: namespace,
        form: empty_form(namespace),
        target: Target.new(nil),
        started: nil,
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
      "init_values" => "",
      "snapshot_interval" => ""
    }
  end

  # ---- Events ----

  @doc false
  def handle_event(module, "launcher_open", _params, socket) do
    target =
      socket.assigns.flezha_token
      |> Target.new()
      |> Target.put_namespaces(module.launcher_namespaces(socket))

    # A screen that asks opens on the namespace the shell has in scope, not on
    # whichever reachable namespace happens to sort first.
    namespace =
      socket.assigns.launcher.fixed_namespace ||
        Target.namespace(target, socket.assigns[:shell_namespace] || "")

    state = %{
      socket.assigns.launcher
      | open?: true,
        step: 0,
        form: empty_form(namespace),
        target: target,
        started: nil,
        error: nil
    }

    put_launcher(socket, aim(state, namespace))
  end

  def handle_event(_module, "launcher_close", _params, socket) do
    update_launcher(socket, &%{&1 | open?: false, started: nil, error: nil})
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

  # The typed-factory fallback changes nothing until it is submitted.
  def handle_event(_module, "launcher_change", _params, socket), do: socket

  # Choosing a factory moves on to its details; an unserved one cannot be
  # chosen, whatever the client sends.
  def handle_event(_module, "launcher_pick", %{"factory" => factory_id}, socket) do
    state = socket.assigns.launcher

    case Enum.find(state.target.factories, &(&1.id == factory_id)) do
      %{servable?: false} ->
        socket

      _known_or_typed ->
        put_launcher(socket, %{
          state
          | form: Map.put(state.form, "factory_id", factory_id),
            step: 1,
            error: nil
        })
    end
  end

  # The details are checked before the review, so the review states what
  # would start and nothing is sent until Start.
  def handle_event(_module, "launcher_next", params, socket) do
    state = socket.assigns.launcher
    form = Map.merge(state.form, params["start"] || %{})

    case details(state, form) do
      :ok -> put_launcher(socket, %{state | form: form, step: 2, error: nil})
      {:error, error} -> put_launcher(socket, %{state | form: form, error: error})
    end
  end

  def handle_event(_module, "launcher_back", _params, socket) do
    update_launcher(socket, &%{&1 | step: max(&1.step - 1, 0), error: nil})
  end

  # A second click while the first start is answered starts nothing more.
  def handle_event(
        _module,
        "launcher_submit",
        _params,
        %{assigns: %{launcher: %{started: started}}} = socket
      )
      when started != nil,
      do: socket

  def handle_event(module, "launcher_submit", params, socket) do
    state = socket.assigns.launcher
    form = Map.merge(state.form, params["start"] || %{})
    socket = put_launcher(socket, %{state | form: form})

    case start(state, form, socket.assigns.flezha_token) do
      {:ok, started} ->
        socket
        |> update_launcher(&%{&1 | started: started, error: nil})
        |> then(&module.refresh/1)

      {:error, error} ->
        update_launcher(socket, &%{&1 | error: error})
    end
  end

  defp start(state, form, token) do
    namespace = String.trim(form["namespace"] || "")
    id = String.trim(form["id"] || "")
    factory_id = String.trim(form["factory_id"] || "")

    with :ok <- require_namespace(namespace),
         :ok <- require_factories(state.target),
         :ok <- require_factory(factory_id),
         {:ok, init_values} <- NodeManager.parse_init_values(form["init_values"]) do
      fields = %{id: id, factory_id: factory_id, init_values: init_values, opts: build_opts(form)}

      case NodeManager.start_relay(namespace, fields, token) do
        {:ok, %{id: started, outcome: outcome}} ->
          {:ok, %{namespace: namespace, id: to_string(started), outcome: outcome}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp details(state, form) do
    with :ok <- require_namespace(String.trim(form["namespace"] || "")),
         :ok <- require_factories(state.target),
         :ok <- require_factory(String.trim(form["factory_id"] || "")),
         {:ok, _init_values} <- NodeManager.parse_init_values(form["init_values"]) do
      :ok
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

  defp require_factory(""), do: {:error, "A Factory ID is required."}
  defp require_factory(_factory_id), do: :ok

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

  @doc "The guided start, as a dialog: Factory, then Details, then Review."
  attr :launcher, :map, required: true

  def launcher_dialog(assigns) do
    assigns =
      assign(assigns,
        factory:
          Enum.find(
            assigns.launcher.target.factories,
            &(&1.id == assigns.launcher.form["factory_id"])
          )
      )

    ~H"""
    <.dialog :if={@launcher.open?} testid="start-modal" size="form" on_close="launcher_close">
      <:title>Start a relay</:title>

      <%!-- What the controller answered: the id the relay runs under, which it
            generates when none was asked for, and whether this call started it. --%>
      <div :if={@launcher.started} data-testid="start-result" class="space-y-4">
        <.notice icon="hero-check-circle">
          <span :if={@launcher.started.outcome == :already_running}>
            A relay with that id is already running in {@launcher.started.namespace}:
          </span>
          <span :if={@launcher.started.outcome != :already_running}>
            Relay started in {@launcher.started.namespace}:
          </span>
          <.link
            navigate={~p"/namespaces/#{@launcher.started.namespace}/relays/#{@launcher.started.id}"}
            data-testid="start-result-link"
            class="fui-num"
          >
            {@launcher.started.id}
          </.link>
        </.notice>
        <div class="flex justify-end">
          <.button phx-click="launcher_close" data-testid="start-done-btn">Done</.button>
        </div>
      </div>

      <.steps
        :if={is_nil(@launcher.started)}
        steps={["Factory", "Details", "Review"]}
        current={@launcher.step}
        testid="start-steps"
      >
        <.form_error error={@launcher.error} action="the start" testid="start-error" />

        <%!-- Factory --%>
        <div :if={@launcher.step == 0} class="space-y-4">
          <form :if={is_nil(@launcher.fixed_namespace)} phx-change="launcher_change">
            <Target.namespace_field
              target={@launcher.target}
              name="start[namespace]"
              label="Namespace"
              value={@launcher.form["namespace"]}
              testid="input-namespace"
            />
          </form>
          <p :if={@launcher.fixed_namespace}>
            Into <span class="fui-num">{@launcher.fixed_namespace}</span>. Pick the
            factory the relay starts from.
          </p>
          <.notice :if={Target.no_factories?(@launcher.target)} testid="start-no-factories">
            {Target.no_factories_message()}: a runner registers its factories when it connects.
          </.notice>
          <.runtime_error error={Target.catalog_error(@launcher.target)} action="the factory listing" />
          <form
            :if={Target.catalog_error(@launcher.target)}
            phx-change="launcher_change"
            phx-submit="launcher_pick"
            class="flex items-end gap-2"
          >
            <.input
              type="text"
              name="factory"
              label="Factory id"
              value={@launcher.form["factory_id"]}
              mono
              data-testid="input-factory-id"
            />
            <.button type="submit" data-testid="start-typed-factory">Continue</.button>
          </form>
          <div :if={@launcher.target.factories != []} data-fui-filterable class="space-y-2">
            <input
              type="search"
              placeholder="Find a factory"
              aria-label="Find a factory"
              data-fui-filter
              data-testid="factory-search"
            />
            <div class="fui-choices" data-testid="factory-choices">
              <button
                :for={factory <- @launcher.target.factories}
                type="button"
                class="fui-choice"
                data-fui-item
                phx-click="launcher_pick"
                phx-value-factory={factory.id}
                disabled={factory.servable? == false}
                aria-pressed={to_string(factory.id == @launcher.form["factory_id"])}
                data-testid={"factory-choice-#{factory.id}"}
              >
                <span class="flex flex-wrap items-center gap-2">
                  <span class="fui-num font-medium">{factory.id}</span>
                  <.chip :if={factory.run}>{factory.run}</.chip>
                </span>
                <span :if={factory.description} class="fui-quiet text-sm">{factory.description}</span>
                <span class="fui-muted text-xs">
                  {if factory.servable? == false,
                    do: "Unavailable: no runner serves it right now.",
                    else: "Served by " <> Words.count(length(factory.runners || []), "runner") <> "."}
                </span>
              </button>
            </div>
          </div>
        </div>

        <%!-- Details --%>
        <form
          :if={@launcher.step == 1}
          id="start-details"
          phx-change="launcher_change"
          phx-submit="launcher_next"
          class="space-y-4"
        >
          <p>
            A relay from <span class="fui-num">{@launcher.form["factory_id"]}</span>{if @factory &&
                                                                                          @factory.run,
                                                                                        do:
                                                                                          ", which runs as #{@factory.run}"}.
          </p>
          <.input
            type="text"
            name="start[id]"
            label="Relay id"
            hint="Optional — the controller generates one when left empty."
            value={@launcher.form["id"]}
            placeholder="my-relay"
            maxlength="32"
            mono
            data-testid="input-relay-id"
          />
          <.input
            type="textarea"
            name="start[init_values]"
            label="Init values"
            hint="JSON, optional: the factory declares no typed fields."
            value={@launcher.form["init_values"]}
            placeholder="{}"
            mono
            data-testid="input-init-values"
          />
          <.input
            type="number"
            name="start[snapshot_interval]"
            label="Snapshot interval"
            hint="Optional."
            value={@launcher.form["snapshot_interval"]}
            data-testid="input-snapshot-interval"
          />
        </form>

        <%!-- Review --%>
        <div :if={@launcher.step == 2} class="space-y-2" data-testid="start-review">
          <p class="fui-sentence" data-testid="start-review-sentence">
            Start a {(@factory && @factory.run) || ""} relay from
            <span class="fui-num">{@launcher.form["factory_id"]}</span>
            in <span class="fui-num">{@launcher.form["namespace"]}</span>,
            <%= if String.trim(@launcher.form["id"] || "") == "" do %>
              under an id the controller generates.
            <% else %>
              as <span class="fui-num">{String.trim(@launcher.form["id"])}</span>.
            <% end %>
          </p>
          <p :if={String.trim(@launcher.form["init_values"] || "") != ""} class="fui-figures">
            With init values <code>{@launcher.form["init_values"]}</code>.
          </p>
        </div>

        <:foot>
          <.button
            :if={@launcher.step == 0}
            variant="ghost"
            phx-click="launcher_close"
            data-testid="start-cancel-btn"
          >
            Cancel
          </.button>
          <.button
            :if={@launcher.step > 0}
            variant="ghost"
            phx-click="launcher_back"
            data-testid="start-back-btn"
          >
            Back
          </.button>
          <span :if={@launcher.step == 0} class="fui-figures">Choose a factory to go on.</span>
          <.button
            :if={@launcher.step == 1}
            type="submit"
            form="start-details"
            data-testid="start-next-btn"
          >
            Review
          </.button>
          <.button
            :if={@launcher.step == 2}
            phx-click="launcher_submit"
            phx-disable-with="Starting…"
            data-testid="start-submit-btn"
            disabled={Target.no_factories?(@launcher.target)}
          >
            Start
          </.button>
        </:foot>
      </.steps>
    </.dialog>
    """
  end
end
