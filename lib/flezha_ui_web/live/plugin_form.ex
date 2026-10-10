defmodule FlezhaUiWeb.Live.PluginForm do
  @moduledoc """
  Every write that configures a plugin — enable, bind and update — as one form.

  Reachable from two screens: a relay's detail page, where enabling binds the
  new plugin to that relay, and the plugins screen, where a plugin is enabled
  into a namespace and an enabled one is bound to a further relay or given new
  options. One form because the fields, the provider's help and the call
  shapes are the same, and a write path implemented twice drifts.

      use FlezhaUiWeb.Live.PluginForm

      def mount(_params, _session, socket) do
        {:ok, socket |> start_refresh() |> plugin_form_init() |> refresh()}
      end

  The host renders `plugin_form_dialog/1` and points a control at the
  `plugin_form_open` event with `phx-value-mode` (`enable`, `bind` or
  `update`) and what it already knows: `namespace`, `relay` for a relay the
  plugin is bound to, `name`, `provider` and comma-joined `hooks` for an
  enabled plugin. On success
  the dialog closes, the outcome is flashed and the host's `refresh/1` runs.

  The provider's `type` decides the fields: a controller plugin runs on
  controllers rather than on a relay, so it is asked for controller hooks and
  `single` and never for a relay; a relay plugin is asked for a relay and its
  relay hooks. The hooks offered are the ones the provider says it supports.

  The provider's `options` decide how its options are asked for: one typed
  field per option, checked by `FlezhaUiWeb.Live.TypedFields` before anything
  is sent, with a refusal that names an option put on its field. A controller
  that does not list them gets one JSON object field instead.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Live.Target
  alias FlezhaUiWeb.Live.TypedFields

  # Named exactly and namespaced, so a host's own events are never swallowed.
  @events ~w(plugin_form_open plugin_form_close plugin_form_provider plugin_form_change
             plugin_form_submit)

  @doc false
  defmacro __using__(_opts) do
    events = @events

    quote do
      import FlezhaUiWeb.Live.PluginForm, only: [plugin_form_init: 1, plugin_form_dialog: 1]

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) when event in unquote(events) do
        {:noreply, FlezhaUiWeb.Live.PluginForm.handle_event(__MODULE__, event, params, socket)}
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

    form = %{
      mode: mode,
      namespace: namespace,
      relay: blank_to_nil(params["relay"]),
      target: if(namespace, do: nil, else: Target.load_namespaces(Target.new(token))),
      providers: [],
      providers_error: nil,
      provider: nil,
      options: nil,
      relays: [],
      relays_error: nil,
      fields: %{
        "name" => params["name"] || generated_name(),
        "namespace" => namespace || "",
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

  def handle_event(_module, "plugin_form_provider", %{"provider" => id}, socket) do
    update(socket, :plugin_form, &choose(&1, id, socket.assigns.flezha_token))
  end

  # A form with no field of its own to post, such as an update of a relay
  # plugin that takes no options, arrives without `plugin`.
  def handle_event(_module, "plugin_form_change", params, socket) do
    form = socket.assigns.plugin_form
    fields = merge(form.fields, Map.get(params, "plugin", %{}))

    form =
      if fields["namespace"] != form.fields["namespace"],
        do: load_relays(%{form | fields: fields}, socket.assigns.flezha_token),
        else: %{form | fields: fields}

    assign(socket, plugin_form: form)
  end

  def handle_event(module, "plugin_form_submit", params, socket) do
    form = socket.assigns.plugin_form
    form = %{form | fields: merge(form.fields, Map.get(params, "plugin", %{}))}

    case submit(form, socket.assigns.flezha_token) do
      {:ok, message} ->
        socket
        |> assign(plugin_form: nil)
        |> Phoenix.LiveView.put_flash(:info, message)
        |> then(&module.refresh/1)

      {:error, {:fields, errors}} ->
        assign(socket, plugin_form: %{form | error: nil, option_errors: errors})

      {:error, error} ->
        assign(socket, plugin_form: %{form | error: error, option_errors: []})
    end
  end

  # An enabled plugin's hooks arrive with the open event as one comma-joined
  # value, so an update starts from the hooks it has.
  defp split(nil), do: []
  defp split(hooks), do: hooks |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp mode("bind"), do: :bind
  defp mode("update"), do: :update
  defp mode(_enable), do: :enable

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

  @doc "The plugin form, as a modal."
  attr :form, :map, required: true

  def plugin_form_dialog(assigns) do
    ~H"""
    <.dialog
      :if={@form}
      testid="attach-modal"
      size="form"
      on_close="plugin_form_close"
      close_testid="attach-close-btn"
    >
      <:title>{title(@form)}</:title>

      <%= if is_nil(@form.provider) do %>
        <.runtime_error error={@form.providers_error} action="the provider listing" />
        <p :if={@form.providers == [] and is_nil(@form.providers_error)} class="flz-empty">
          This controller offers no plugin providers.
        </p>
        <div data-testid="provider-grid" class="grid grid-cols-2 gap-3">
          <button
            :for={provider <- @form.providers}
            phx-click="plugin_form_provider"
            phx-value-provider={provider.id}
            data-testid={"provider-btn-#{provider.id}"}
            class="flz-card flz-card--link group text-left"
          >
            <div class="flex items-center gap-2">
              <.icon
                name="hero-cube"
                class="w-4 h-4 text-th-secondary group-hover:text-th-brand transition-colors"
              />
              <p class="text-sm font-medium text-th-primary">{Format.humanize(provider.id)}</p>
            </div>
            <p class="text-xs text-th-secondary mt-1 font-mono">
              {provider.id}<span :if={provider[:type]}> · {provider.type}</span>
            </p>
          </button>
        </div>
      <% else %>
        <.form_error error={@form.error} action="the plugin" testid="attach-error" />

        <%!-- The browser's own checks would stop a bounded number before the
              form's, which say on the field what is wrong. --%>
        <form
          phx-submit="plugin_form_submit"
          phx-change="plugin_form_change"
          novalidate
          class="space-y-4"
        >
          <.input
            :if={@form.mode == :enable}
            type="text"
            name="plugin[name]"
            label="Plugin name"
            value={@form.fields["name"]}
            mono
            data-testid="input-plugin-name"
          />

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
            label="Relay *"
            value={@form.fields["relay_id"]}
            options={Enum.map(@form.relays, &{&1, &1})}
            prompt="Select a relay..."
            empty="No relay is running in this namespace"
            error={@form.relays_error}
            mono
            testid="input-plugin-relay"
          />

          <fieldset :if={@form.mode != :update or controller?(@form)} data-testid="input-hooks">
            <legend class="flz-label mb-2">
              {if controller?(@form), do: "Controller hooks", else: "Hooks"}
            </legend>
            <p :if={@form.provider.hooks == []} class="text-xs text-th-muted">
              The controller did not say which hooks this provider supports.
            </p>
            <input type="hidden" name="plugin[hooks][]" value="" />
            <label
              :for={hook <- @form.provider.hooks}
              class="flex items-center gap-2 text-sm text-th-secondary"
            >
              <input
                type="checkbox"
                name="plugin[hooks][]"
                value={hook}
                checked={to_string(hook) in List.wrap(@form.fields["hooks"])}
                data-testid={"input-hook-#{hook}"}
              />
              <span class="font-mono">{hook}</span>
            </label>
          </fieldset>

          <label
            :if={@form.mode == :enable and controller?(@form)}
            class="flex items-center gap-2 text-sm text-th-secondary"
          >
            <input type="hidden" name="plugin[single]" value="false" />
            <input
              type="checkbox"
              name="plugin[single]"
              value="true"
              checked={@form.fields["single"] == "true"}
              data-testid="input-plugin-single"
            /> One copy for the whole cluster (single)
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

          <%!-- The provider's own help, when it answers any; the options field
                renders without it rather than the form failing. Open when it is
                the only description of the options. --%>
          <details
            :if={@form.provider.help}
            data-testid="provider-help"
            open={@form.options == :json}
          >
            <summary class="text-xs text-th-brand cursor-pointer">
              {Format.humanize(@form.provider.id)} options
            </summary>
            <pre class="flz-code flz-code--wrap mt-2 max-h-64">{@form.provider.help}</pre>
          </details>

          <%= if @form.mode != :bind do %>
            <%= case @form.options do %>
              <% {:fields, specs} -> %>
                <TypedFields.typed_inputs
                  specs={specs}
                  form={
                    to_form(map_or_empty(@form.fields["opts"]),
                      as: "plugin[opts]",
                      errors: @form.option_errors
                    )
                  }
                  secret_name="plugin[secret]"
                  testid="input-option-"
                />
              <% :none -> %>
                <p class="text-xs text-th-muted" data-testid="plugin-no-options">
                  This provider takes no options.
                </p>
              <% :json -> %>
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
            <% end %>
          <% end %>

          <div class="flex justify-between pt-2">
            <.button variant="ghost" phx-click="plugin_form_close" data-testid="attach-cancel-btn">
              Cancel
            </.button>
            <.button type="submit" data-testid="attach-submit-btn">{submit_label(@form)}</.button>
          </div>
        </form>
      <% end %>
    </.dialog>
    """
  end

  defp title(%{mode: :bind, fields: fields}), do: "Bind #{fields["name"]}"
  defp title(%{mode: :update, fields: fields}), do: "Update #{fields["name"]}"
  defp title(%{provider: nil}), do: "Choose Provider"
  defp title(_form), do: "Configure Plugin"

  defp submit_label(%{mode: :bind}), do: "Bind"
  defp submit_label(%{mode: :update}), do: "Update"
  defp submit_label(%{relay: relay}) when is_binary(relay), do: "Attach"
  defp submit_label(_form), do: "Enable"
end
