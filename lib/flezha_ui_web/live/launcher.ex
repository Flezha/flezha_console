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

  It is a guided flow of three steps down a rail: Factory (searchable, each
  with its description, its run and how many runners serve it, an unserved one
  shown unavailable with that reason, and the chosen one described beside the
  list), Details (the optional id and the init values, checked as they are
  typed), and Review (one sentence saying what will start, the facts, the
  `flz relay start` that does the same, then Start). How a relay
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
      "init_values" => ""
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

  # Choosing a listed factory describes it beside the list; a typed one, which
  # the catalog could not describe, moves on to its details. An unserved one
  # cannot be chosen, whatever the client sends.
  def handle_event(_module, "launcher_pick", %{"factory" => factory_id}, socket) do
    state = socket.assigns.launcher
    form = Map.put(state.form, "factory_id", factory_id)

    case Enum.find(state.target.factories, &(&1.id == factory_id)) do
      %{servable?: false} -> socket
      nil -> put_launcher(socket, %{state | form: form, step: 1, error: nil})
      _listed -> put_launcher(socket, %{state | form: form, error: nil})
    end
  end

  # Each step is checked before the next opens, so the review states what
  # would start and nothing is sent until Start.
  def handle_event(_module, "launcher_next", params, socket) do
    state = socket.assigns.launcher
    form = Map.merge(state.form, params["start"] || %{})
    target = min(state.step + 1, 2)

    case move_step(state.step, target, 2, fn -> details(state, form) end) do
      {:ok, step} -> put_launcher(socket, %{state | form: form, step: step, error: nil})
      {:error, error} -> put_launcher(socket, %{state | form: form, error: error})
    end
  end

  # A step named goes back to that step; none goes back one. Neither goes
  # forward.
  def handle_event(_module, "launcher_back", params, socket) do
    update_launcher(socket, fn state ->
      target =
        case Integer.parse(to_string(params["step"])) do
          {step, ""} -> min(step, state.step)
          _one_back -> state.step - 1
        end

      {:ok, step} = move_step(state.step, target, 2, fn -> :ok end)
      %{state | step: step, error: nil}
    end)
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
      fields = %{id: id, factory_id: factory_id, init_values: init_values}

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
         {:ok, _init_values} <- init_values(state.step, form) do
      :ok
    end
  end

  # The init values are asked for on Details, so the Factory step does not
  # read them.
  defp init_values(0, _form), do: {:ok, %{}}
  defp init_values(_step, form), do: NodeManager.parse_init_values(form["init_values"])

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

  # ---- Catalog ----

  defp aim(state, namespace) do
    {target, form} = Target.aim(state.target, namespace, state.form)

    %{state | target: target, form: form}
  end

  defp put_launcher(socket, state), do: assign(socket, launcher: state)

  defp update_launcher(socket, fun),
    do: put_launcher(socket, fun.(socket.assigns.launcher))

  # ---- Rendering ----

  defp run_meaning(run) when run in [:flow, "flow"],
    do: "Each record passes through its tasklets once, as it arrives."

  defp run_meaning(run) when run in [:steps, "steps"],
    do: "Durable steps: each committed step is journaled, so the relay resumes where it was."

  defp run_meaning(_run), do: "As the factory's runners announce it."

  # A glyph and a hue per run, which only tell the cards apart.
  defp run_glyph(run) when run in [:flow, "flow"], do: {"hero-arrow-long-right", 1}
  defp run_glyph(run) when run in [:steps, "steps"], do: {"hero-queue-list", 4}
  defp run_glyph(_run), do: {"hero-cube", 5}

  @doc "The guided start, as a dialog: Factory, then Details, then Review."
  attr :launcher, :map, required: true

  def launcher_dialog(assigns) do
    form = assigns.launcher.form

    assigns =
      assign(assigns,
        factory: Enum.find(assigns.launcher.target.factories, &(&1.id == form["factory_id"])),
        relay_id: String.trim(form["id"] || ""),
        init_values: NodeManager.parse_init_values(form["init_values"])
      )

    assigns = assign(assigns, command: command(form, assigns.relay_id, assigns.init_values))

    ~H"""
    <.dialog
      :if={@launcher.open?}
      testid="start-modal"
      size={if @launcher.started, do: "form", else: "flow"}
      on_close="launcher_close"
    >
      <:title>Start a relay</:title>

      <%!-- What the controller answered: the id the relay runs under, which it
            generates when none was asked for, and whether this call started it. --%>
      <div :if={@launcher.started} data-testid="start-result" class="fui-done">
        <span class="fui-done-mark"><.icon name="hero-check" class="h-8 w-8" /></span>
        <p class="fui-sentence fui-sentence--headline">
          {if @launcher.started.outcome == :already_running,
            do: "Already running",
            else: "Relay started"}
        </p>
        <p class="fui-quiet">
          <span :if={@launcher.started.outcome == :already_running}>
            A relay with that id is already running in {@launcher.started.namespace}, so nothing
            new was started:
          </span>
          <span :if={@launcher.started.outcome != :already_running}>
            It runs in {@launcher.started.namespace} as
          </span>
          <.link
            navigate={~p"/namespaces/#{@launcher.started.namespace}/relays/#{@launcher.started.id}"}
            data-testid="start-result-link"
            class="fui-num"
          >
            {@launcher.started.id}
          </.link>
        </p>
        <div class="flex flex-wrap justify-center gap-2">
          <.button
            variant="secondary"
            navigate={~p"/namespaces/#{@launcher.started.namespace}/relays/#{@launcher.started.id}"}
            icon_right="hero-arrow-right-mini"
          >
            Open the relay
          </.button>
          <.button phx-click="launcher_close" data-testid="start-done-btn">Done</.button>
        </div>
      </div>

      <.steps
        :if={is_nil(@launcher.started)}
        steps={rail(@launcher, @factory, @relay_id, @init_values)}
        current={@launcher.step}
        rail
        on_step="launcher_back"
        testid="start-steps"
      >
        <:aside>
          A relay runs as its factory says, so a start names only the factory. The
          review shows the matching <code>flz relay start</code>.
        </:aside>
        <.form_error error={@launcher.error} action="the start" testid="start-error" />

        <%!-- Factory --%>
        <div :if={@launcher.step == 0} class="fui-flow-section">
          <form :if={is_nil(@launcher.fixed_namespace)} phx-change="launcher_change">
            <Target.namespace_field
              target={@launcher.target}
              name="start[namespace]"
              label="Namespace"
              value={@launcher.form["namespace"]}
              testid="input-namespace"
            />
          </form>
          <p :if={@launcher.fixed_namespace} class="fui-quiet">
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
          <.picker
            :if={@launcher.target.factories != []}
            search="Find a factory"
            search_testid="factory-search"
            list_testid="factory-choices"
          >
            <:tools>
              <span class="fui-figures">
                {Words.count(length(@launcher.target.factories), "factory", "factories")}
              </span>
            </:tools>
            <.pick_choice
              :for={factory <- @launcher.target.factories}
              chosen={factory.id == @launcher.form["factory_id"]}
              glyph={run_glyph(factory.run)}
              phx-click="launcher_pick"
              phx-value-factory={factory.id}
              disabled={factory.servable? == false}
              data-testid={"factory-choice-#{factory.id}"}
            >
              <span class="flex flex-wrap items-center gap-2">
                <span class="fui-num font-medium">{factory.id}</span>
                <.chip :if={factory.run}>{factory.run}</.chip>
              </span>
              <span :if={factory.description} class="fui-quiet block text-sm">
                {factory.description}
              </span>
              <span class="fui-muted block text-xs">
                {if factory.servable? == false,
                  do: "Unavailable: no runner serves it right now.",
                  else: "Served by " <> Words.count(length(factory.runners || []), "runner") <> "."}
              </span>
            </.pick_choice>
            <:detail><.factory_detail factory={@factory} /></:detail>
          </.picker>
        </div>

        <%!-- Details --%>
        <form
          :if={@launcher.step == 1}
          id="start-details"
          phx-change="launcher_change"
          phx-submit="launcher_next"
          class="fui-flow-section"
        >
          <p class="fui-quiet">
            A relay from
            <span class="fui-num">{@launcher.form["factory_id"]}</span><span :if={
              @factory && @factory.run
            }>, which runs as {@factory.run}</span>. Both fields are optional.
          </p>
          <.input
            type="text"
            name="start[id]"
            label="Relay id"
            hint={
              "The name the relay runs under. Left empty, the controller generates one: " <>
                "#{@launcher.form["factory_id"]}-<16 characters>. Give one when the start may " <>
                "be retried: starting an id that already runs starts nothing."
            }
            value={@launcher.form["id"]}
            placeholder="my-relay"
            maxlength="32"
            mono
            data-testid="input-relay-id"
          />
          <div>
            <.input
              type="textarea"
              name="start[init_values]"
              label="Initial values"
              hint={
                ~s(A JSON object keyed by tasklet name, such as {"ohlc": {"1m": {"high": 0}}}. A name the factory does not carry is ignored, not refused, so check the spelling.)
              }
              value={@launcher.form["init_values"]}
              placeholder="{}"
              rows="5"
              mono
              data-testid="input-init-values"
            />
            <p class="fui-flow-check" data-testid="init-values-check">
              <%= case @init_values do %>
                <% {:ok, values} when values == %{} -> %>
                  <.icon name="hero-minus-circle-mini" class="h-4 w-4" />
                  None: each tasklet starts with the state its class builds.
                <% {:ok, values} when is_map(values) -> %>
                  <span class="fui-tone-positive inline-flex items-center gap-1">
                    <.icon name="hero-check-circle-mini" class="h-4 w-4" />
                    Seeds {Words.count(map_size(values), "tasklet")}:
                  </span>
                  <span class="fui-num">
                    {values |> Map.keys() |> Enum.sort() |> Enum.join(", ")}
                  </span>
                <% {:ok, _value} -> %>
                  <.icon name="hero-information-circle-mini" class="h-4 w-4" />
                  Valid JSON, though not an object keyed by tasklet.
                <% {:error, message} -> %>
                  <span class="fui-tone-negative inline-flex items-center gap-1">
                    <.icon name="hero-exclamation-circle-mini" class="h-4 w-4" /> {message}
                  </span>
              <% end %>
            </p>
          </div>
        </form>

        <%!-- Review: what will be started, one fact per line --%>
        <div :if={@launcher.step == 2} class="fui-flow-section" data-testid="start-review">
          <p class="fui-sentence fui-sentence--headline">
            Start a relay from <span class="fui-num">{@launcher.form["factory_id"]}</span>
            in <span class="fui-num">{@launcher.form["namespace"]}</span>, {if @relay_id == "",
              do: "under an id the controller generates",
              else: "as"}
            <span :if={@relay_id != ""} class="fui-num">{@relay_id}</span>.
          </p>
          <dl class="fui-review" data-testid="start-review-facts">
            <div class="fui-review-row">
              <dt>Factory</dt>
              <dd data-testid="review-factory">
                <span class="fui-num">{@launcher.form["factory_id"]}</span>
                <span :if={@factory && @factory[:description]} class="fui-review-note">
                  {@factory.description}
                </span>
                <span :if={is_nil(@factory)} class="fui-review-note">
                  Not in the catalog this console read; the controller checks it on start.
                </span>
              </dd>
            </div>
            <div :if={@factory && @factory.run} class="fui-review-row">
              <dt>Runs as</dt>
              <dd data-testid="review-run">
                <span class="fui-num">{@factory.run}</span>
                <span class="fui-review-note">{run_meaning(@factory.run)}</span>
              </dd>
            </div>
            <div class="fui-review-row">
              <dt>Namespace</dt>
              <dd class="fui-num" data-testid="review-namespace">{@launcher.form["namespace"]}</dd>
            </div>
            <div class="fui-review-row">
              <dt>Relay id</dt>
              <dd data-testid="review-id">
                <span :if={@relay_id == ""} class="fui-review-note">
                  Generated by the controller when it starts.
                </span>
                <span :if={@relay_id != ""} class="fui-num">{@relay_id}</span>
              </dd>
            </div>
            <div :if={@factory} class="fui-review-row">
              <dt>Served by</dt>
              <dd data-testid="review-runners">
                <%= if (@factory[:runners] || []) == [] do %>
                  <span class="fui-tone-warning">No runner serves this factory right now.</span>
                <% else %>
                  {Words.count(length(@factory.runners), "runner")}:
                  <span class="fui-num">{Enum.join(@factory.runners, ", ")}</span>
                <% end %>
              </dd>
            </div>
            <div class="fui-review-row">
              <dt>Initial values</dt>
              <dd data-testid="review-init-values">
                <%= case @init_values do %>
                  <% {:ok, values} when values == %{} -> %>
                    <span class="fui-review-note">None.</span>
                  <% {:ok, values} when is_map(values) -> %>
                    <dl class="fui-review-values">
                      <div :for={{key, value} <- Enum.sort(values)}>
                        <dt class="fui-num">{key}</dt>
                        <dd class="fui-num">{Jason.encode!(value)}</dd>
                      </div>
                    </dl>
                  <% {:ok, value} -> %>
                    <code>{Jason.encode!(value)}</code>
                  <% {:error, message} -> %>
                    <span class="fui-tone-negative">{message} Go back to Details to fix it.</span>
                <% end %>
              </dd>
            </div>
          </dl>
          <.command id="start-command" testid="start-command" command={@command} />
        </div>

        <:foot>
          <.button variant="ghost" phx-click="launcher_close" data-testid="start-cancel-btn">
            Cancel
          </.button>
          <.button
            :if={@launcher.step > 0}
            variant="secondary"
            phx-click="launcher_back"
            data-testid="start-back-btn"
          >
            Back
          </.button>
          <.button
            :if={@launcher.step == 0}
            phx-click="launcher_next"
            disabled={is_nil(@factory)}
            icon_right="hero-arrow-right-mini"
            data-testid="start-next-btn"
          >
            Continue
          </.button>
          <.button
            :if={@launcher.step == 1}
            type="submit"
            form="start-details"
            icon_right="hero-arrow-right-mini"
            data-testid="start-next-btn"
          >
            Review
          </.button>
          <.button
            :if={@launcher.step == 2}
            phx-click="launcher_submit"
            phx-disable-with="Starting…"
            icon="hero-play-mini"
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

  # Each step and what was chosen there, or what it will ask.
  defp rail(launcher, factory, relay_id, init_values) do
    factory_id = launcher.form["factory_id"]

    details =
      if launcher.step > 1 do
        id = if relay_id == "", do: "Generated id", else: relay_id

        case init_values do
          {:ok, values} when is_map(values) and map_size(values) > 0 ->
            "#{id} · #{Words.count(map_size(values), "tasklet")} seeded"

          _none ->
            id
        end
      else
        "Its id and initial values"
      end

    [
      {"Factory",
       cond do
         factory_id in [nil, ""] -> "What the relay starts from"
         factory && factory.run -> "#{factory_id} · #{factory.run}"
         true -> factory_id
       end},
      {"Details", details},
      {"Review", "Check, copy the command, start"}
    ]
  end

  # What the chosen factory is, how it runs and who serves it.
  attr :factory, :map, default: nil

  defp factory_detail(%{factory: nil} = assigns) do
    ~H"""
    <.pick_pane testid="factory-detail" empty="hero-cube">
      Choose a factory to see how its relays run and which runners serve it.
    </.pick_pane>
    """
  end

  defp factory_detail(assigns) do
    ~H"""
    <.pick_pane
      testid="factory-detail"
      glyph={run_glyph(@factory.run)}
      title={@factory.id}
      subtitle={@factory.run && "runs as #{@factory.run}"}
      mono={:title}
    >
      <p :if={@factory.description} class="fui-quiet text-sm">{@factory.description}</p>
      <div>
        <p class="fui-eyebrow mb-1">How it runs</p>
        <p class="fui-quiet text-sm">{run_meaning(@factory.run)}</p>
      </div>
      <div>
        <p class="fui-eyebrow mb-1">Served by</p>
        <p :if={(@factory.runners || []) == []} class="fui-tone-warning text-sm">
          No runner serves it right now.
        </p>
        <div class="flex flex-wrap gap-1">
          <.chip :for={runner <- @factory.runners || []} mono>{runner}</.chip>
        </div>
      </div>
      <:action>
        <.button
          phx-click="launcher_next"
          icon_right="hero-arrow-right-mini"
          data-testid="factory-use-btn"
        >
          Use {@factory.id}
        </.button>
      </:action>
    </.pick_pane>
    """
  end

  # The `flz relay start` that does what the review states.
  defp command(form, relay_id, init_values) do
    init =
      case init_values do
        {:ok, values} when values != %{} -> ["--init-values", Jason.encode!(values)]
        _none -> []
      end

    Format.command(
      ["flz", "relay", "start", String.trim(form["factory_id"] || "")] ++
        ["--namespace", String.trim(form["namespace"] || "")] ++
        if(relay_id == "", do: [], else: ["--id", relay_id]) ++ init
    )
  end
end
