defmodule FlezhaConsoleWeb.Live.PluginForm do
  @moduledoc """
  Every write that configures a plugin — enable, bind and update — as one form.

  Reachable from two screens: a relay's detail page, where enabling binds the
  new plugin to that relay, and the plugins screen, where a plugin is enabled
  into a namespace and an enabled one is bound to a further relay or given new
  options. One form because the fields, the provider's help and the call
  shapes are the same, and a write path implemented twice drifts.

      use FlezhaConsoleWeb.Live.PluginForm

      def mount(_params, _session, socket) do
        {:ok, socket |> start_refresh() |> plugin_form_init() |> refresh()}
      end

  The host renders `plugin_form_dialog/1` and points a control at the
  `plugin_form_open` event with `phx-value-mode` (`enable`, `bind` or
  `update`) and what it already knows: `namespace`, `relay` for a relay the
  plugin is bound to, `name`, `provider` and comma-joined `hooks` for an
  enabled plugin. On success
  the dialog closes, the outcome is flashed and the host's `refresh/1` runs.

  Enabling is a guided flow down a rail: Provider (grouped by what it does,
  with what it asks for beside the list), Placement (name, namespace, relay,
  hooks), Options and Review, which states what will be enabled and the `flz`
  command that does the same. All the fields stay in one form whichever step
  is shown, so a value typed in one step is still there in the next, and each
  step is checked before the next opens. Binding and updating ask for less and
  are one page.

  The provider's `type` decides the fields: a controller plugin runs on
  controllers rather than on a relay, so it is asked for controller hooks and
  `single` and never for a relay; a relay plugin is asked for a relay and its
  relay hooks. The hooks offered are the ones the provider says it supports.

  The provider's `options` decide how its options are asked for: one typed
  field per option, checked by `FlezhaConsoleWeb.Live.TypedFields` before anything
  is sent, with a refusal that names an option put on its field. A controller
  that does not list them gets one JSON object field instead.
  """

  use FlezhaConsoleWeb, :html

  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.Live.Target
  alias FlezhaConsoleWeb.Live.TypedFields

  # Named exactly and namespaced, so a host's own events are never swallowed.
  @events ~w(plugin_form_open plugin_form_close plugin_form_provider plugin_form_change
             plugin_form_submit plugin_form_step plugin_form_role plugin_form_rename
             plugin_form_fold)

  # The enable flow's steps: Provider, Placement, Options, Review.
  @placement 1
  @options 2
  @review 3

  @doc false
  defmacro __using__(_opts) do
    events = @events

    quote do
      import FlezhaConsoleWeb.Live.PluginForm, only: [plugin_form_init: 1, plugin_form_dialog: 1]

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) when event in unquote(events) do
        {:noreply,
         FlezhaConsoleWeb.Live.PluginForm.handle_event(__MODULE__, event, params, socket)}
      end
    end
  end

  @doc "The closed form. Call before the first load."
  def plugin_form_init(socket), do: assign(socket, plugin_form: nil)

  # ---- Events ----

  @doc false
  def handle_event(_module, "plugin_form_open", params, socket) do
    token = socket.assigns.flezha_token
    mode = mode(params["mode"])
    namespace = blank_to_nil(params["namespace"])
    target = if(namespace, do: nil, else: Target.load_namespaces(Target.new(token)))

    form = %{
      mode: mode,
      step: 0,
      role: nil,
      unfolded: false,
      namespace: namespace,
      relay: blank_to_nil(params["relay"]),
      target: target,
      providers: [],
      providers_error: nil,
      provider: nil,
      options: nil,
      relays: [],
      relays_error: nil,
      fields: %{
        "name" => params["name"] || generated_name(),
        # A screen that asks opens on the namespace the shell has in scope.
        "namespace" =>
          namespace || Target.namespace(target, socket.assigns[:shell_namespace] || ""),
        "opts" => "",
        "secret" => %{},
        "hooks" => split(params["hooks"]),
        "relay_id" => "",
        "channel" => "",
        "single" => "false"
      },
      error: nil,
      option_errors: []
    }

    form =
      if mode == :enable,
        do: load_providers(form, token),
        else: choose(form, params["provider"], token)

    assign(socket, plugin_form: form)
  end

  def handle_event(_module, "plugin_form_close", _params, socket),
    do: assign(socket, plugin_form: nil)

  # A form event that lands after the dialog closed has nothing to act on.
  def handle_event(_module, _event, _params, %{assigns: %{plugin_form: nil}} = socket),
    do: socket

  # Another provider asks for other hooks and options, so what was typed for
  # the last one is dropped rather than sent to this one.
  def handle_event(_module, "plugin_form_provider", %{"provider" => id}, socket) do
    update(socket, :plugin_form, fn
      %{provider: %{id: ^id}} = form ->
        form

      form ->
        fields = %{form.fields | "hooks" => [], "opts" => "", "secret" => %{}}
        choose(%{form | fields: fields, option_errors: []}, id, socket.assigns.flezha_token)
    end)
  end

  def handle_event(_module, "plugin_form_step", %{"step" => step}, socket) do
    case Integer.parse(to_string(step)) do
      {step, ""} -> update(socket, :plugin_form, &goto(&1, step))
      _not_a_step -> socket
    end
  end

  def handle_event(_module, "plugin_form_role", params, socket) do
    role = Enum.find(~w(source tap controller)a, &(Atom.to_string(&1) == params["value"]))
    update(socket, :plugin_form, &%{&1 | role: role})
  end

  def handle_event(_module, "plugin_form_fold", _params, socket) do
    update(socket, :plugin_form, &%{&1 | unfolded: not &1.unfolded})
  end

  def handle_event(_module, "plugin_form_rename", _params, socket) do
    update(socket, :plugin_form, &%{&1 | fields: Map.put(&1.fields, "name", generated_name())})
  end

  # A form with no field of its own to post, such as an update of a relay
  # plugin that takes no options, arrives without `plugin`.
  def handle_event(_module, "plugin_form_change", params, socket) do
    form = socket.assigns.plugin_form
    fields = merge(form.fields, own_params(form, params))

    # An option's error stands until its value is changed.
    changed =
      for key <- ~w(opts secret),
          {name, value} <- map_or_empty(fields[key]),
          map_or_empty(form.fields[key])[name] != value,
          do: name

    form = %{form | option_errors: Enum.reject(form.option_errors, &(elem(&1, 0) in changed))}

    form =
      if fields["namespace"] != form.fields["namespace"],
        do: load_relays(%{form | fields: fields}, socket.assigns.flezha_token),
        else: %{form | fields: fields}

    assign(socket, plugin_form: form)
  end

  # Before the review, submitting the form (Enter in a field, or Next) moves
  # on a step; only the review's submit enables.
  def handle_event(
        _module,
        "plugin_form_submit",
        params,
        %{assigns: %{plugin_form: %{mode: :enable, step: step}}} = socket
      )
      when step < @review do
    form = socket.assigns.plugin_form

    assign(socket,
      plugin_form: goto(%{form | fields: merge(form.fields, own_params(form, params))}, step + 1)
    )
  end

  def handle_event(module, "plugin_form_submit", params, socket) do
    form = socket.assigns.plugin_form
    form = %{form | fields: merge(form.fields, own_params(form, params))}

    case submit(form, socket.assigns.flezha_token) do
      {:ok, message} ->
        socket
        |> assign(plugin_form: nil)
        |> Phoenix.LiveView.put_flash(:info, message)
        |> then(&module.refresh/1)

      {:error, {:fields, errors}} ->
        step = if form.mode == :enable, do: @options, else: form.step
        assign(socket, plugin_form: %{form | step: step, error: nil, option_errors: errors})

      {:error, error} ->
        assign(socket, plugin_form: %{form | error: error, option_errors: []})
    end
  end

  # Forward only past a step whose checks pass, so the review never states
  # what cannot be sent. Binding and updating have no steps to move through.
  defp goto(form, target) do
    last = if form.mode == :enable, do: @review, else: 0

    case move_step(form.step, target, last, fn -> check(form) end) do
      {:ok, step} when step > form.step -> %{form | step: step, error: nil, option_errors: []}
      {:ok, step} -> %{form | step: step, error: nil}
      {:error, {:fields, errors}} -> %{form | error: nil, option_errors: errors}
      {:error, error} -> %{form | error: error}
      :stay -> form
    end
  end

  defp check(%{step: 0, provider: nil}), do: {:error, "Choose a provider to go on."}
  defp check(%{step: 0}), do: :ok

  defp check(%{step: @placement} = form) do
    with :ok <- required(String.trim(form.fields["name"] || ""), "A plugin name is required."),
         do: required(namespace(form), "A namespace is required.")
  end

  defp check(%{step: @options} = form) do
    with {:ok, _opts} <- options_value(form, required?: true), do: :ok
  end

  # An enabled plugin's hooks arrive with the open event as one comma-joined
  # value, so an update starts from the hooks it has.
  defp split(nil), do: []
  defp split(hooks), do: hooks |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp mode("bind"), do: :bind
  defp mode("update"), do: :update
  defp mode(_enable), do: :enable

  # On an enable each step takes only its own fields. The others' inputs are
  # still in the form, hidden, but a value the browser lets go of there must
  # not overwrite what the operator chose on their step.
  @step_fields %{
    @placement => ~w(name namespace relay_id hooks single),
    @options => ~w(opts secret)
  }

  defp own_params(%{mode: :enable, step: step}, params),
    do: Map.take(Map.get(params, "plugin", %{}), Map.get(@step_fields, step, []))

  defp own_params(_form, params), do: Map.get(params, "plugin", %{})

  # A checkbox group posts nothing when every box is cleared, so the hidden
  # empty entry is what tells a cleared group from an untouched one. Typed
  # options and secrets arrive as maps keyed by option name and are folded in
  # key by key.
  defp merge(fields, params) do
    params
    |> Map.update(
      "hooks",
      fields["hooks"],
      &Enum.reject(List.wrap(&1), fn hook -> hook == "" end)
    )
    |> Enum.reduce(fields, fn
      {key, %{} = given}, acc when key in ~w(opts secret) ->
        Map.update(acc, key, given, &Map.merge(map_or_empty(&1), given))

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_text), do: %{}

  # ---- Providers and relays ----

  # The controller lists only the providers of packages it loaded, so a refused
  # package's are never offered.
  defp load_providers(form, token) do
    case NodeManager.providers(token) do
      {:ok, %{providers: providers}} -> %{form | providers: providers}
      {:error, reason} -> %{form | providers_error: reason}
    end
  end

  # The provider's own description — its help, its type, the hooks it
  # supports and its options — read once on selection rather than on every
  # keystroke. One whose help cannot be read still renders the form, as a relay
  # plugin with the JSON options field.
  defp choose(form, id, token) do
    provider =
      case NodeManager.provider(id, token) do
        {:ok, described} -> Map.put(described, :id, id)
        {:error, _reason} -> %{id: id, help: nil, type: nil, hooks: []}
      end

    form = %{form | provider: provider, options: options(provider, form.mode), error: nil}
    load_relays(form, token)
  end

  # How the options are asked for: `{:fields, specs}`, `:none` for a provider
  # that lists none, or `:json` for a controller that does not list them.
  defp options(%{options: [_ | _] = rows}, mode) do
    case option_specs(rows, mode) do
      [] -> :none
      specs -> if TypedFields.fits?(specs), do: {:fields, specs}, else: :json
    end
  end

  defp options(%{options: []}, _mode), do: :none
  defp options(_described, _mode), do: :json

  @doc false
  # The controller's option rows as typed-field specs. Names and types are read
  # as text whether they arrive as strings or atoms, so no atom is made.
  def option_specs(rows, mode) do
    for row <- rows, kind = option_kind(row), kind != nil do
      %{
        name: to_string(row.name),
        kind: kind,
        required: mode == :enable and Map.get(row, :required) == true,
        default: Map.get(row, :default),
        min: Map.get(row, :min),
        max: Map.get(row, :max),
        values: Map.get(row, :values),
        doc: option_doc(row, mode)
      }
    end
  end

  # No operator can type a process, so a `pid` option is not offered.
  defp option_kind(row) do
    type = row |> Map.get(:type, :any) |> to_string()

    cond do
      type == "pid" -> nil
      Map.get(row, :transient) == true -> :secret
      type == "int" -> :int
      type == "bool" -> :bool
      type == "enum" and is_list(Map.get(row, :values)) -> :enum
      type == "string" -> :string
      type in ~w(names list) -> :list
      type == "map" -> :object
      true -> :json
    end
  end

  defp option_doc(row, :update) do
    said =
      if Map.get(row, :live) == true, do: "changed in place", else: "a change restarts the plugin"

    Enum.join(Enum.reject([Map.get(row, :doc), said], &(&1 in [nil, ""])), " — ")
  end

  defp option_doc(row, _mode), do: Map.get(row, :doc)

  # The relay picker is read only when the form asks for a relay at all.
  defp load_relays(%{relay: relay} = form, _token) when is_binary(relay), do: form

  defp load_relays(form, token) do
    namespace = namespace(form)

    if asks_relay?(form) and namespace != "" do
      {relays, error} = NodeManager.ok_or_error(NodeManager.list_relays(namespace, token), [])
      %{form | relays: Enum.sort(relays), relays_error: error}
    else
      %{form | relays: [], relays_error: nil}
    end
  end

  @doc "Whether the chosen provider runs on controllers rather than on a relay."
  def controller?(%{provider: %{type: :controller}}), do: true
  def controller?(_form), do: false

  @doc "Whether the form asks which relay the plugin binds to."
  def asks_relay?(%{mode: :update}), do: false
  def asks_relay?(%{relay: relay}) when is_binary(relay), do: false
  def asks_relay?(form), do: not controller?(form)

  defp namespace(form), do: form.namespace || String.trim(form.fields["namespace"] || "")

  # ---- Submitting ----

  defp submit(%{mode: :enable} = form, token) do
    name = String.trim(form.fields["name"] || "")

    with :ok <- required(name, "A plugin name is required."),
         :ok <- required(namespace(form), "A namespace is required."),
         {:ok, opts} <- options_value(form, required?: true) do
      fields = %{
        provider: form.provider.id,
        opts: opts,
        namespace: namespace(form),
        relay_id: if(controller?(form), do: nil, else: relay(form)),
        hooks: form.fields["hooks"],
        single: controller?(form) and form.fields["single"] == "true"
      }

      case NodeManager.enable_plugin(name, fields, token) do
        {:ok, answer} -> {:ok, enabled_message(name, fields.relay_id, answer)}
        {:error, reason} -> refusal(form, reason)
      end
    end
  end

  defp submit(%{mode: :bind} = form, token) do
    name = form.fields["name"]
    relay_id = relay(form)

    with :ok <- required(relay_id, "A relay is required.") do
      fields = %{
        namespace: namespace(form),
        relay_id: relay_id,
        hooks: form.fields["hooks"],
        channel: String.trim(form.fields["channel"] || "")
      }

      with {:ok, outcome} <- NodeManager.bind_plugin(name, fields, token),
           do: {:ok, bound_message(name, relay_id, outcome)}
    end
  end

  defp submit(%{mode: :update} = form, token) do
    name = form.fields["name"]

    with {:ok, opts} <- options_value(form, required?: false) do
      fields = %{
        namespace: namespace(form),
        opts: opts,
        hooks: if(controller?(form), do: form.fields["hooks"])
      }

      case NodeManager.update_plugin(name, fields, token) do
        {:ok, answer} -> {:ok, updated_message(name, answer)}
        {:error, reason} -> refusal(form, reason)
      end
    end
  end

  defp relay(%{relay: relay}) when is_binary(relay), do: relay
  defp relay(form), do: String.trim(form.fields["relay_id"] || "")

  defp required("", message), do: {:error, message}
  defp required(_value, _message), do: :ok

  # Only the options given are sent, each in its type and keyed by its name as
  # text, so the controller applies its own defaults to the rest. Secrets are
  # read from their own params, which are never rendered back.
  defp options_value(%{options: {:fields, specs}, fields: fields}, required?: required?) do
    {secrets, typed} = Enum.split_with(specs, &(&1.kind == :secret))

    params =
      Map.merge(
        Map.take(map_or_empty(fields["opts"]), Enum.map(typed, & &1.name)),
        Map.take(map_or_empty(fields["secret"]), Enum.map(secrets, & &1.name))
      )

    case specs |> TypedFields.changeset(params, required?: required?) |> TypedFields.values() do
      {:ok, opts} -> {:ok, opts}
      {:error, errors} -> {:error, {:fields, errors}}
    end
  end

  defp options_value(%{options: :none}, _required), do: {:ok, %{}}
  defp options_value(form, _required), do: parse_opts(form.fields["opts"])

  # A refusal that names options the form offers is put on their fields, so the
  # operator sees which one to change; any other stays on the form. A secret's
  # field gets the code alone, because the controller's message may carry the
  # value.
  defp refusal(%{options: {:fields, specs}}, reason) do
    %{code: code, message: message, details: details} = NodeManager.error(reason)
    named = named_options(details)

    case Enum.filter(specs, &(&1.name in named)) do
      [] ->
        {:error, reason}

      offered ->
        {:error, {:fields, Enum.map(offered, &{&1.name, refused(&1, code, message)})}}
    end
  end

  defp refusal(_form, reason), do: {:error, reason}

  defp named_options(details) do
    for key <- ~w(option options required other),
        name <- List.wrap(Map.get(details, key)),
        is_binary(name) or (is_atom(name) and not is_nil(name)),
        do: to_string(name)
  end

  defp refused(%{kind: :secret}, code, _message),
    do: {"The controller refused this value (%{code}).", code: code}

  defp refused(_spec, code, message), do: {"%{message} (%{code})", message: message, code: code}

  # A controller that does not list its options gets them as one JSON object,
  # keyed by text: the controller turns only names the provider declares into
  # atoms.
  defp parse_opts(raw) do
    case String.trim(raw || "") do
      "" ->
        {:ok, %{}}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = opts} -> {:ok, opts}
          _not_an_object -> {:error, "Options must be a JSON object."}
        end
    end
  end

  @doc false
  def enabled_message(name, relay_id, answer) do
    outcome =
      case {answer.outcome, relay_id} do
        {:already_enabled, nil} ->
          "Plugin #{name} was already enabled."

        {:already_enabled, _relay} ->
          "Plugin #{name} was already enabled; this relay is bound to it."

        {_enabled, nil} ->
          "Plugin #{name} enabled."

        {_enabled, relay} ->
          "Plugin #{name} enabled and bound to #{relay}."
      end

    case Map.get(answer, :lacking, []) do
      [] ->
        outcome

      lacking ->
        outcome <>
          " It does not run on #{Enum.map_join(lacking, ", ", &to_string/1)}, which " <>
          "lack#{if length(lacking) == 1, do: "s"} its provider."
    end
  end

  defp bound_message(name, relay_id, :already_bound),
    do: "#{relay_id} already holds plugin #{name}."

  defp bound_message(name, relay_id, :bound), do: "Plugin #{name} bound to #{relay_id}."

  defp updated_message(name, %{applied: applied} = answer) do
    how =
      case applied do
        :live -> "applied live"
        :restarted -> "applied by restarting its copies"
        :unchanged -> "nothing changed"
      end

    relays = Map.get(answer, :relays, [])

    "Plugin #{name} updated: #{how}." <>
      if(relays == [], do: "", else: " Bound to #{Enum.join(relays, ", ")}.")
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp generated_name do
    "plugin-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end

  # ---- Rendering ----

  @doc """
  What a provider is for, read from what the controller says of it: one that
  feeds its relay is a source, any other relay provider takes what its relay
  carries, and a controller provider runs beside the controllers.
  """
  def role(%{type: :controller}), do: :controller
  def role(%{feeds: true}), do: :source
  def role(_provider), do: :tap

  # Each role's heading, what it does, and its glyph, whose hue only tells the
  # groups apart: what a role means is said in words.
  @roles [
    source: %{
      heading: "Sources",
      does: "Feeds records into the relay it is bound to.",
      glyph: {"hero-arrow-down-tray", 0}
    },
    tap: %{
      heading: "Taps and sinks",
      does: "Takes what its relay takes in or puts out.",
      glyph: {"hero-arrows-right-left", 3}
    },
    controller: %{
      heading: "Controller plugins",
      does: "Runs beside the controllers, not on a relay.",
      glyph: {"hero-server-stack", 2}
    }
  ]

  defp role_info(role), do: Keyword.fetch!(@roles, role)

  # What each hook a provider may name does, in the words of the CLI's help.
  # The controller answers a hook's name alone.
  @hook_docs %{
    "on_input" => "Each record the relay takes in",
    "on_output" => "Each record the relay puts out",
    "on_interval" => "On a timer; its interval is set from the CLI",
    "on_terminate" => "When the relay stops, to let go of what it holds",
    "on_message" => "Requests sent to the relay, answered in turn",
    "on_call" => "Each call made to the relay",
    "on_preview" => "Each part or dead-letter notice, for listeners",
    "on_relay_started" => "A relay starts",
    "on_relay_stopped" => "A relay stops",
    "on_relay_failed" => "A relay fails",
    "on_dead_letter" => "A record is dead-lettered",
    "on_plugin_unhealthy" => "A plugin reports itself unhealthy"
  }

  defp hook_doc(hook), do: Map.get(@hook_docs, to_string(hook))

  @doc "The plugin form, as a modal."
  attr :form, :map, required: true

  def plugin_form_dialog(assigns) do
    ~H"""
    <.dialog
      :if={@form}
      testid="attach-modal"
      size={if @form.mode == :enable, do: "flow", else: "form"}
      on_close="plugin_form_close"
      close_testid="attach-close-btn"
    >
      <:title>{title(@form)}</:title>

      <%= if @form.mode == :enable do %>
        <.steps
          steps={rail(@form)}
          current={@form.step}
          rail
          on_step="plugin_form_step"
          testid="plugin-steps"
        >
          <:aside>
            Every choice is a flag of <code>flz plugin enable</code>. The review
            shows the whole command, ready to copy.
          </:aside>
          <.form_error error={@form.error} action="the plugin" testid="attach-error" />
          <.provider_step :if={@form.step == 0} form={@form} />
          <.plugin_fields :if={@form.provider} form={@form} />
          <:foot>
            <.button variant="ghost" phx-click="plugin_form_close" data-testid="attach-cancel-btn">
              Cancel
            </.button>
            <.button
              :if={@form.step > 0}
              variant="secondary"
              phx-click="plugin_form_step"
              phx-value-step={@form.step - 1}
              data-testid="attach-back-btn"
            >
              Back
            </.button>
            <.button
              :if={@form.step == 0}
              phx-click="plugin_form_step"
              phx-value-step="1"
              disabled={is_nil(@form.provider)}
              icon_right="hero-arrow-right-mini"
              data-testid="attach-next-btn"
            >
              Continue
            </.button>
            <.button
              :if={@form.step in [1, 2]}
              type="submit"
              form="plugin-form"
              icon_right="hero-arrow-right-mini"
              data-testid="attach-next-btn"
            >
              {if @form.step == 1, do: "Options", else: "Review"}
            </.button>
            <.button
              :if={@form.step == 3}
              type="submit"
              form="plugin-form"
              phx-disable-with="Enabling…"
              icon="hero-check-mini"
              data-testid="attach-submit-btn"
            >
              {submit_label(@form)}
            </.button>
          </:foot>
        </.steps>
      <% else %>
        <.form_error error={@form.error} action="the plugin" testid="attach-error" />
        <.plugin_fields form={@form} />
      <% end %>
    </.dialog>
    """
  end

  # Each step and what was chosen there, or what it will ask.
  defp rail(form) do
    [
      {"Provider",
       if(form.provider, do: Format.humanize(form.provider.id), else: "What implements it")},
      {"Placement", placement_summary(form)},
      {"Options", options_summary(form)},
      {"Review", "Check, copy the command, enable"}
    ]
  end

  defp placement_summary(%{step: step} = form) when step > @placement do
    relay = bound_relay(form)
    name = String.trim(form.fields["name"] || "")

    "#{name} in #{namespace(form)}" <> if(relay == "", do: "", else: " → #{relay}")
  end

  defp placement_summary(form) do
    if controller?(form),
      do: "Name, namespace, hooks and copies",
      else: "Name, namespace, relay and hooks"
  end

  defp options_summary(%{step: step} = form) when step > @options do
    case Enum.count(given_options(form)) do
      0 -> "The provider's defaults"
      n -> Words.count(n, "option") <> " set"
    end
  end

  defp options_summary(form), do: options_asked(form)

  # What the provider will ask for.
  defp options_asked(%{options: {:fields, specs}}) do
    case Enum.count(specs, & &1.required) do
      0 -> Words.count(length(specs), "option") <> ", all optional"
      n -> "#{n} required of #{length(specs)}"
    end
  end

  defp options_asked(%{options: :none}), do: "None to set"
  defp options_asked(%{options: :json}), do: "One JSON object"
  defp options_asked(_form), do: "What the provider asks for"

  # ---- Provider step ----

  attr :form, :map, required: true

  defp provider_step(assigns) do
    roles = Enum.map(assigns.form.providers, &role/1)

    groups =
      for {role, _info} <- @roles,
          assigns.form.role in [nil, role],
          providers = Enum.filter(assigns.form.providers, &(role(&1) == role)),
          providers != [],
          do: {role, providers}

    assigns = assign(assigns, roles: @roles, counts: Enum.frequencies(roles), groups: groups)

    ~H"""
    <.runtime_error error={@form.providers_error} action="the provider listing" />
    <p :if={@form.providers == [] and is_nil(@form.providers_error)} class="fcon-figures">
      This controller offers no plugin providers.
    </p>
    <.picker
      :if={@form.providers != []}
      search="Find a provider"
      search_testid="provider-search"
      list_testid="provider-grid"
    >
      <:tools>
        <.segmented label="What it does" testid="provider-roles">
          <:option
            click="plugin_form_role"
            value=""
            current={is_nil(@form.role)}
            testid="provider-role-all"
          >
            All <span class="fcon-count fcon-count--neutral">{length(@form.providers)}</span>
          </:option>
          <:option
            :for={{role, info} <- @roles}
            :if={@counts[role]}
            click="plugin_form_role"
            value={Atom.to_string(role)}
            current={@form.role == role}
            testid={"provider-role-#{role}"}
          >
            {info.heading} <span class="fcon-count fcon-count--neutral">{@counts[role]}</span>
          </:option>
        </.segmented>
      </:tools>
      <section :for={{role, providers} <- @groups} class="fcon-pick-group">
        <h3 class="fcon-eyebrow">{role_info(role).heading}</h3>
        <.pick_choice
          :for={provider <- providers}
          chosen={chosen?(@form, provider)}
          glyph={role_info(role).glyph}
          phx-click="plugin_form_provider"
          phx-value-provider={provider.id}
          data-testid={"provider-btn-#{provider.id}"}
        >
          <span class="block font-medium">{Format.humanize(provider.id)}</span>
          <span class="fcon-num fcon-muted text-xs">{provider.id}</span>
        </.pick_choice>
      </section>
      <:detail><.provider_detail form={@form} /></:detail>
    </.picker>
    """
  end

  defp chosen?(%{provider: %{id: id}}, %{id: id}), do: true
  defp chosen?(_form, _provider), do: false

  # What the chosen provider is, the hooks it takes and what it will ask for,
  # so the choice is made before the form, not discovered in it.
  attr :form, :map, required: true

  defp provider_detail(%{form: %{provider: nil}} = assigns) do
    ~H"""
    <.pick_pane testid="provider-detail" empty="hero-puzzle-piece">
      Choose a provider to see what it does, the hooks it takes and what it asks of you.
    </.pick_pane>
    """
  end

  defp provider_detail(assigns) do
    provider = assigns.form.provider
    listed = listed(assigns.form)
    role = role(listed)

    assigns =
      assign(assigns,
        provider: provider,
        module: Map.get(listed, :module),
        role: role,
        info: role_info(role),
        needs:
          case assigns.form.options do
            {:fields, specs} -> Enum.filter(specs, & &1.required)
            _other -> []
          end
      )

    ~H"""
    <.pick_pane
      testid="provider-detail"
      glyph={@info.glyph}
      title={Format.humanize(@provider.id)}
      subtitle={@module || @provider.id}
      mono={:subtitle}
    >
      <div class="flex flex-wrap gap-1">
        <.chip>{@info.heading}</.chip>
        <.chip>runs on {if @role == :controller, do: "the controllers", else: "a relay"}</.chip>
        <.chip>{options_asked(@form)}</.chip>
      </div>
      <p class="fcon-quiet text-sm">{@info.does}</p>
      <div>
        <p class="fcon-eyebrow mb-1">Hooks it can use</p>
        <p :if={(@provider.hooks || []) == []} class="fcon-quiet text-sm">
          None: it runs on its own once enabled.
        </p>
        <div class="flex flex-wrap gap-1">
          <.chip :for={hook <- @provider.hooks || []} mono title={hook_doc(hook)}>{hook}</.chip>
        </div>
      </div>
      <div :if={@needs != []}>
        <p class="fcon-eyebrow mb-1">You will need</p>
        <dl class="fcon-pane-needs">
          <div :for={spec <- @needs}>
            <dt class="fcon-num">{spec.name}</dt>
            <dd class="fcon-quiet">{code_names(spec.doc || "")}</dd>
          </div>
        </dl>
      </div>
      <:action>
        <.button
          phx-click="plugin_form_step"
          phx-value-step="1"
          icon_right="hero-arrow-right-mini"
          data-testid="provider-use-btn"
        >
          Use {Format.humanize(@provider.id)}
        </.button>
      </:action>
    </.pick_pane>
    """
  end

  # ---- The form: placement, options and review ----

  # Every field is rendered whichever step is shown, so what was typed in a
  # step the operator moved on from is still in the form, and is sent.
  attr :form, :map, required: true

  defp plugin_fields(assigns) do
    assigns = assign(assigns, flow?: assigns.form.mode == :enable)

    ~H"""
    <%!-- The browser's own checks would stop a bounded number before the
          form's, which say on the field what is wrong. --%>
    <form
      id="plugin-form"
      data-testid="plugin-form"
      phx-submit="plugin_form_submit"
      phx-change="plugin_form_change"
      novalidate
      class="fcon-flow-form"
    >
      <section
        hidden={@flow? and @form.step != 1}
        class="fcon-flow-section"
        data-testid="plugin-placement"
      >
        <div :if={@form.mode == :enable}>
          <div class="flex items-end gap-2">
            <div class="min-w-0 flex-1">
              <.input
                type="text"
                name="plugin[name]"
                label="Plugin name"
                value={@form.fields["name"]}
                mono
                data-testid="input-plugin-name"
              />
            </div>
            <button
              type="button"
              class="fcon-iconbtn"
              phx-click="plugin_form_rename"
              aria-label="Another name"
              title="Another name"
              data-testid="plugin-rename-btn"
            >
              <.icon name="hero-arrow-path" class="h-5 w-5" />
            </button>
          </div>
          <p class="fcon-hint">
            How the plugin is known in its namespace: bind, update and disable name it.
          </p>
        </div>

        <Target.namespace_field
          :if={@form.target}
          target={@form.target}
          name="plugin[namespace]"
          label="Namespace *"
          value={@form.fields["namespace"]}
          testid="input-plugin-namespace"
        />

        <.enumerated_field
          :if={asks_relay?(@form)}
          name="plugin[relay_id]"
          label={if @form.mode == :bind, do: "Relay *", else: "Relay"}
          hint={
            if @form.mode == :enable,
              do: "Bound now, it runs at once. Left empty, it waits until a relay is bound to it."
          }
          value={@form.fields["relay_id"]}
          options={Enum.map(@form.relays, &{&1, &1})}
          prompt={if @form.mode == :bind, do: "Select a relay...", else: "None yet: bind it later"}
          empty="No relay is running in this namespace"
          error={@form.relays_error}
          mono
          testid="input-plugin-relay"
        />

        <fieldset :if={@form.mode != :update or controller?(@form)} data-testid="input-hooks">
          <legend class="fcon-label">
            {if controller?(@form), do: "Controller hooks", else: "Hooks"}
          </legend>
          <p class="fcon-hint mb-2">
            {if controller?(@form),
              do: "The cluster events the plugin is told of.",
              else: "When the relay calls the plugin. A plugin that only feeds its relay needs none."}
          </p>
          <p :if={@form.provider.hooks == []} class="fcon-figures">
            The controller did not say which hooks this provider supports.
          </p>
          <input type="hidden" name="plugin[hooks][]" value="" />
          <div :if={@form.provider.hooks != []} class="fcon-choices fcon-choices--tiles">
            <label :for={hook <- @form.provider.hooks} class="fcon-choice">
              <input
                type="checkbox"
                name="plugin[hooks][]"
                value={hook}
                checked={to_string(hook) in List.wrap(@form.fields["hooks"])}
                data-testid={"input-hook-#{hook}"}
              />
              <span class="grid">
                <span class="fcon-num font-medium">{hook}</span>
                <span :if={hook_doc(hook)} class="fcon-muted text-xs">{hook_doc(hook)}</span>
              </span>
            </label>
          </div>
        </fieldset>

        <label :if={@form.mode == :enable and controller?(@form)} class="fcon-choice">
          <input type="hidden" name="plugin[single]" value="false" />
          <input
            type="checkbox"
            name="plugin[single]"
            value="true"
            checked={@form.fields["single"] == "true"}
            data-testid="input-plugin-single"
          />
          <span class="grid">
            <span class="font-medium">One copy for the whole cluster</span>
            <span class="fcon-muted text-xs">
              Otherwise each controller holding the namespace runs its own copy.
            </span>
          </span>
        </label>

        <.input
          :if={@form.mode == :bind}
          type="text"
          name="plugin[channel]"
          label="Channel"
          hint="optional"
          value={@form.fields["channel"]}
          mono
          data-testid="input-plugin-channel"
        />
      </section>

      <section
        :if={@form.mode != :bind}
        hidden={@flow? and @form.step != 2}
        class="fcon-flow-section"
        data-testid="plugin-options"
      >
        <.option_fields form={@form} />

        <%!-- The provider's own help, when it answers any; the options field
              renders without it rather than the form failing. Open when it is
              the only description of the options. --%>
        <%!-- Keyed by provider, and its `open` left to the browser once mounted,
              so a re-render never folds what the operator unfolded. --%>
        <details
          :if={@form.provider.help}
          id={"provider-help-#{@form.provider.id}"}
          data-testid="provider-help"
          class="fcon-disclosure"
          open={@form.options == :json}
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary>What {Format.humanize(@form.provider.id)} does, and its options</summary>
          <.code_block class="mt-2">{@form.provider.help}</.code_block>
        </details>
      </section>

      <.review :if={@flow? and @form.step == 3} form={@form} />

      <div :if={not @flow?} class="flex justify-between pt-2">
        <.button variant="ghost" phx-click="plugin_form_close" data-testid="attach-cancel-btn">
          Cancel
        </.button>
        <.button type="submit" data-testid="attach-submit-btn">{submit_label(@form)}</.button>
      </div>
    </form>
    """
  end

  # Required options first; the rest are folded away on an enable, where the
  # provider's defaults stand for any left empty. The fold is the server's
  # state, not a `<details>`, whose `open` every re-render would reset; it is
  # open when the operator unfolded it, when nothing is required, or when one
  # of its options was refused.
  attr :form, :map, required: true

  defp option_fields(%{form: %{options: {:fields, specs}}} = assigns) do
    {required, optional} = Enum.split_with(specs, & &1.required)
    opts = map_or_empty(assigns.form.fields["opts"])
    refused = Enum.map(assigns.form.option_errors, &elem(&1, 0))

    assigns =
      assign(assigns,
        required: required,
        optional: optional,
        fold?: assigns.form.mode == :enable and optional != [],
        open?:
          assigns.form.unfolded or required == [] or
            Enum.any?(optional, &(&1.name in refused)),
        options_form: to_form(opts, as: "plugin[opts]", errors: assigns.form.option_errors)
      )

    ~H"""
    <div :if={@required != []} class="fcon-flow-group">
      <p class="fcon-label">Required</p>
      <div class="fcon-flow-fields">
        <TypedFields.typed_inputs
          specs={@required}
          form={@options_form}
          secret_name="plugin[secret]"
          testid="input-option-"
        />
      </div>
    </div>
    <div :if={@fold?} class="fcon-disclosure">
      <button
        type="button"
        class="fcon-disclosure-toggle"
        phx-click="plugin_form_fold"
        aria-expanded={to_string(@open?)}
        aria-controls="plugin-optional"
        data-testid="plugin-optional-toggle"
      >
        <.icon name="hero-chevron-right-mini" class="fcon-disclosure-mark h-4 w-4" />
        Optional · {length(@optional)}
        <span class="fcon-muted">the provider's defaults stand for any left empty</span>
      </button>
      <div id="plugin-optional" hidden={not @open?} class="fcon-flow-fields mt-3">
        <TypedFields.typed_inputs
          specs={@optional}
          form={@options_form}
          secret_name="plugin[secret]"
          testid="input-option-"
        />
      </div>
    </div>
    <div :if={not @fold? and @optional != []} class="fcon-flow-fields">
      <TypedFields.typed_inputs
        specs={@optional}
        form={@options_form}
        secret_name="plugin[secret]"
        testid="input-option-"
      />
    </div>
    """
  end

  defp option_fields(%{form: %{options: :none}} = assigns) do
    ~H"""
    <p class="fcon-figures" data-testid="plugin-no-options">This provider takes no options.</p>
    """
  end

  defp option_fields(assigns) do
    ~H"""
    <.input
      type="textarea"
      name="plugin[opts]"
      label="Options"
      hint={
        if @form.mode == :update,
          do: "JSON object — merged into the options the plugin has",
          else: "JSON object, optional"
      }
      value={@form.fields["opts"]}
      placeholder="{}"
      mono
      data-testid="input-plugin-opts"
    />
    """
  end

  # ---- Review ----

  attr :form, :map, required: true

  defp review(assigns) do
    form = assigns.form
    relay = bound_relay(form)

    assigns =
      assign(assigns,
        name: String.trim(form.fields["name"] || ""),
        namespace: namespace(form),
        relay: relay,
        hooks: List.wrap(form.fields["hooks"]),
        given: given_options(form),
        secrets: secret_names(form),
        command: command(form, relay)
      )

    ~H"""
    <section class="fcon-flow-section" data-testid="plugin-review">
      <p class="fcon-sentence fcon-sentence--headline">
        Enable <b>{Format.humanize(@form.provider.id)}</b>
        as <span class="fcon-num">{@name}</span>
        in
        <span class="fcon-num">{@namespace}</span><span :if={@relay != ""}>,
          bound to <span class="fcon-num">{@relay}</span></span>.
      </p>
      <dl class="fcon-review" data-testid="plugin-review-facts">
        <div class="fcon-review-row">
          <dt>Provider</dt>
          <dd>
            <span class="fcon-num">{@form.provider.id}</span>
            <span class="fcon-review-note">{role_info(role(listed(@form))).does}</span>
          </dd>
        </div>
        <div :if={not controller?(@form)} class="fcon-review-row">
          <dt>Relay</dt>
          <dd data-testid="review-relay">
            <span :if={@relay != ""} class="fcon-num">{@relay}</span>
            <span :if={@relay == ""} class="fcon-review-note">
              None yet: nothing runs until a relay is bound to it.
            </span>
          </dd>
        </div>
        <div :if={controller?(@form)} class="fcon-review-row">
          <dt>Copies</dt>
          <dd>
            {if @form.fields["single"] == "true",
              do: "One for the whole cluster",
              else: "One on each controller holding the namespace"}
          </dd>
        </div>
        <div class="fcon-review-row">
          <dt>Hooks</dt>
          <dd data-testid="review-hooks">
            <span :if={@hooks == []} class="fcon-review-note">None.</span>
            <span class="flex flex-wrap gap-1">
              <.chip :for={hook <- @hooks} mono title={hook_doc(hook)}>{hook}</.chip>
            </span>
          </dd>
        </div>
        <div class="fcon-review-row">
          <dt>Options</dt>
          <dd data-testid="review-options">
            <span :if={@given == []} class="fcon-review-note">
              None set: the provider's defaults apply.
            </span>
            <dl :if={@given != []} class="fcon-review-values">
              <div :for={{key, value} <- @given}>
                <dt class="fcon-num">{key}</dt>
                <dd :if={key in @secrets} class="fcon-review-note">set, not shown</dd>
                <dd :if={key not in @secrets} class="fcon-num">{option_text(value)}</dd>
              </div>
            </dl>
          </dd>
        </div>
      </dl>
      <.command id="plugin-command" testid="plugin-command" command={@command}>
        <p :if={Enum.any?(@given, &(elem(&1, 0) in @secrets))} class="fcon-hint">
          A secret is left out of the command: it reads it from an environment variable instead.
        </p>
      </.command>
    </section>
    """
  end

  # The provider as the listing has it, which says whether it feeds its relay.
  defp listed(form), do: Enum.find(form.providers, &(&1.id == form.provider.id)) || form.provider

  # The relay the plugin is bound to on enable, or "" for none.
  defp bound_relay(form), do: if(asks_relay?(form) or form.relay, do: relay(form), else: "")

  # The options the operator filled, in their types, sorted by name.
  defp given_options(form) do
    case options_value(form, required?: false) do
      {:ok, opts} -> Enum.sort(opts)
      {:error, _errors} -> []
    end
  end

  defp secret_names(%{options: {:fields, specs}}),
    do: for(%{kind: :secret, name: name} <- specs, do: name)

  defp secret_names(_form), do: []

  # The `flz plugin enable` that does what the review states. A secret is read
  # from an environment variable rather than written into the command.
  defp command(form, relay) do
    secrets = secret_names(form)

    Format.command(
      ["flz", "plugin", "enable", String.trim(form.fields["name"] || ""), form.provider.id] ++
        ["--namespace", namespace(form)] ++
        if(relay != "", do: ["--relay_id", relay], else: []) ++
        Enum.map(List.wrap(form.fields["hooks"]), &["--hook=", to_string(&1)]) ++
        if(controller?(form) and form.fields["single"] == "true", do: ["--single"], else: []) ++
        for {key, value} <- given_options(form) do
          if key in secrets,
            do: ["--X", key, "=", {:raw, ~s("$#{env_name(key)}")}],
            else: ["--X", key, "=", option_text(value)]
        end
    )
  end

  defp env_name(key), do: key |> String.upcase() |> String.replace(~r/[^A-Z0-9_]/, "_")

  # A typed value as the CLI takes it: text as written, a list or an object as
  # JSON, which the CLI decodes when a value opens with a bracket.
  defp option_text(value) when is_binary(value), do: value
  defp option_text(value) when is_list(value) or is_map(value), do: Jason.encode!(value)
  defp option_text(value), do: to_string(value)

  defp title(%{mode: :bind, fields: fields}), do: "Bind #{fields["name"]}"
  defp title(%{mode: :update, fields: fields}), do: "Update #{fields["name"]}"
  defp title(%{relay: relay}) when is_binary(relay), do: "Attach a plugin to #{relay}"
  defp title(_form), do: "Enable a plugin"

  defp submit_label(%{mode: :bind}), do: "Bind"
  defp submit_label(%{mode: :update}), do: "Update"
  defp submit_label(%{relay: relay}) when is_binary(relay), do: "Attach"
  defp submit_label(_form), do: "Enable"
end
