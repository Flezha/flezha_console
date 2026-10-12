defmodule FlezhaUiWeb.CoreComponents do
  @moduledoc """
  The console's component kit: one function component per element, each
  drawn by one `fui-` recipe in `assets/css/console/components.css`.

  A screen composes these and adds layout utilities; it never declares a
  colour, a border, a radius or a padding for one of them. Every component is
  shown in every variant and state on the dev-only `/dev/kit` page.

  Icons are [Heroicons](https://heroicons.com), outline at 16 or 20 px; an
  icon-only control always carries an accessible name.
  """
  use Phoenix.Component
  use Gettext, backend: FlezhaUiWeb.Gettext

  # Refusals link to where a token is stored, so the components need routes.
  use Phoenix.VerifiedRoutes,
    endpoint: FlezhaUiWeb.Endpoint,
    router: FlezhaUiWeb.Router,
    statics: FlezhaUiWeb.static_paths()

  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.Glossary
  alias FlezhaUiWeb.Words
  alias Phoenix.LiveView.JS

  # ======================================================================
  # Page grammar
  # ======================================================================

  @doc """
  The header every screen opens on: the kind of object, its name, one
  sentence about its condition, its actions and its local tabs.

  `crumbs` comes from the shell (`FlezhaUiWeb.Layouts.breadcrumbs/1`) and is
  drawn above the eyebrow on a screen deeper than a destination. `headline`
  sets the sentence in the display face, for a screen whose sentence is the
  point of it.

      <.page_header eyebrow="Relay" title={@relay_id} crumbs={@breadcrumbs}
        tabs={relay_views(@ns, @relay_id, :live)}>
        <:sentence>A flow relay from store_input, running on …</:sentence>
        <:actions><.button variant="danger">Stop</.button></:actions>
      </.page_header>
  """
  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :crumbs, :list, default: []
  attr :tabs, :list, default: [], doc: "`%{label:, path:, current?:, testid:}` per view"
  attr :tabs_label, :string, default: "Views"
  attr :headline, :boolean, default: false
  attr :testid, :string, default: "page-header"
  attr :help, :boolean, default: true, doc: "a ? beside the title opening the screen's help"
  slot :sentence
  slot :figures, doc: "a second line of figures in words"
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="fui-page-header" data-testid={@testid}>
      <.crumbs :if={@crumbs != []} trail={@crumbs} />
      <div class="min-w-0 space-y-2">
        <p class="fui-eyebrow" data-testid="page-eyebrow">{@eyebrow}</p>
        <div class="flex items-center gap-2">
          <h1 class="fui-title" data-testid="page-title">{@title}</h1>
          <button
            :if={@help}
            type="button"
            class="fui-help-tip"
            data-fui-help-open
            aria-label="What this screen is for"
            data-testid="page-help"
          >
            <.icon name="hero-question-mark-circle" class="w-6 h-6" />
          </button>
        </div>
        <p
          :if={@sentence != []}
          class={["fui-sentence", @headline && "fui-sentence--headline"]}
          data-testid="page-sentence"
        >
          {render_slot(@sentence)}
        </p>
        <p :if={@figures != []} class="fui-figures" data-testid="page-figures">
          {render_slot(@figures)}
        </p>
      </div>
      <div :if={@actions != []} class="fui-page-actions">{render_slot(@actions)}</div>
      <.tabs :if={@tabs != []} items={@tabs} label={@tabs_label} />
    </header>
    """
  end

  @doc """
  Where the current screen sits, as a trail of its ancestors. The last crumb
  is the page being read: plain text, marked current, not a link to itself.
  """
  attr :trail, :list, required: true

  def crumbs(assigns) do
    ~H"""
    <nav aria-label="Breadcrumb" data-testid="breadcrumb" class="fui-crumbs">
      <%= for {crumb, index} <- Enum.with_index(@trail) do %>
        <span :if={index > 0} class="fui-crumb-sep" aria-hidden="true">/</span>
        <.link :if={crumb.path} navigate={crumb.path}>{crumb.label}</.link>
        <span :if={!crumb.path} aria-current="page">{crumb.label}</span>
      <% end %>
    </nav>
    """
  end

  @doc """
  An object's views, as tabs. Each tab is its own route and navigates, so a
  view holding a live subscription is not mounted while another is read.
  """
  attr :items, :list, required: true, doc: "`%{label:, path:, current?:, testid:}`"
  attr :label, :string, default: "Views"
  attr :testid, :string, default: nil

  def tabs(assigns) do
    ~H"""
    <nav class="fui-tabs" aria-label={@label} data-testid={@testid}>
      <.link
        :for={item <- @items}
        navigate={item.path}
        aria-current={item[:current?] && "page"}
        data-testid={item[:testid]}
        class="fui-tab"
      >
        {item.label}
      </.link>
    </nav>
    """
  end

  @doc """
  A titled part of a screen, separated from the one above by space and a
  hairline — never drawn as a card.

  Naming a `fold` turns the title into the control that folds the section
  shut. A folded section's `digest` says in a few words what it holds — a
  count, its newest item, its condition — so the operator can judge whether
  to open it. The open state is the screen's own assign
  (`FlezhaUiWeb.Live.Sections`), so the server renders the truth on first
  paint; the `FlzSection` hook restores the viewer's last choice over it.

      <.section fold="journal" open={@sections["journal"]} digest="3 committed, latest 12s ago">
        <:title>Task journal</:title>
        ...
      </.section>
  """
  attr :testid, :string, default: nil
  attr :class, :string, default: nil
  attr :digest, :string, default: nil, doc: "what the section holds, in a few words"
  attr :flush, :boolean, default: false, doc: "true for the first section under a header"

  attr :fold, :string,
    default: nil,
    doc: "the key this section folds and is stored under; without it there is no fold"

  attr :id, :string, default: nil, doc: "defaults to the fold key, which is unique per screen"
  attr :open, :boolean, default: true, doc: "meaningful only with a fold"

  attr :forced, :boolean,
    default: false,
    doc: "true when the screen opened this itself, over both the default and the stored choice"

  attr :help, :string,
    default: nil,
    doc: "what the section is, behind a ? at the right end of the title line"

  slot :title, required: true
  slot :actions, doc: "controls at the right of the title line"
  slot :inner_block, required: true

  def section(assigns) do
    # Not `assign_new/3`: the attribute is always present, defaulted to nil.
    assigns = assign(assigns, :id, assigns.id || assigns.fold)

    ~H"""
    <section
      id={@id}
      phx-hook={@fold && "FlzSection"}
      data-testid={@testid}
      data-open={@fold && to_string(@open)}
      data-section-key={@fold}
      data-section-forced={@fold && to_string(@forced)}
      class={["fui-section", @flush && "fui-section--flush", @class]}
    >
      <div class="fui-section-head">
        <button
          :if={@fold}
          type="button"
          class="fui-section-toggle"
          aria-expanded={to_string(@open)}
          aria-controls={"#{@id}-body"}
          phx-click="section_toggle"
          phx-value-key={@fold}
          data-testid={"section-toggle-#{@fold}"}
        >
          <.icon name="hero-chevron-right-mini" class="fui-chevron w-4 h-4" />
          <.section_title digest={@digest}>{render_slot(@title)}</.section_title>
        </button>
        <.section_title :if={!@fold} digest={@digest}>{render_slot(@title)}</.section_title>
        <div :if={@actions != [] or @help} class="fui-section-actions">
          {render_slot(@actions)}
          <.help_tip :if={@help} id={"help-#{@id || @testid || @fold}"} label="What this section is">
            {@help}
          </.help_tip>
        </div>
      </div>
      <%= if @fold do %>
        <div
          :if={@open}
          id={"#{@id}-body"}
          data-testid={"section-body-#{@fold}"}
          class="fui-section-body"
        >
          {render_slot(@inner_block)}
        </div>
      <% else %>
        <div class="fui-section-body">{render_slot(@inner_block)}</div>
      <% end %>
    </section>
    """
  end

  attr :digest, :string, default: nil
  slot :inner_block, required: true

  defp section_title(assigns) do
    ~H"""
    <h2 class="fui-section-title">
      {render_slot(@inner_block)}
      <span :if={@digest} class="fui-section-digest" data-testid="section-digest">{@digest}</span>
    </h2>
    """
  end

  # ======================================================================
  # Controls
  # ======================================================================

  @doc """
  An action, in one of four variants at two sizes. With `navigate`, `patch`
  or `href` it is a link that looks like the action it leads to.

      <.button>Start</.button>
      <.button variant="secondary" size="sm" icon="hero-plus">Bind</.button>
      <.button variant="danger" phx-click="confirm_stop">Stop</.button>
      <.button variant="ghost" navigate={~p"/cluster"}>Open cluster</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :variant, :string, default: "primary", values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :icon, :string, default: nil
  attr :icon_right, :string, default: nil
  attr :loading, :boolean, default: false
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :method, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value aria-label aria-pressed)

  slot :inner_block, required: true

  def button(%{navigate: nil, patch: nil, href: nil} = assigns) do
    # A button with its own click handler is an action, not a submit: inside a
    # form an untyped button submits it, so a dialog's Cancel would also send
    # the form it cancels.
    assigns = assign(assigns, :type, assigns.type || if(assigns.rest[:"phx-click"], do: "button"))

    ~H"""
    <button
      type={@type}
      disabled={@loading || @rest[:disabled]}
      class={button_class(@variant, @size, @class)}
      {@rest}
    >
      <.icon :if={@loading} name="hero-arrow-path" class={["fui-spin", icon_size(@size)]} />
      <.icon :if={@icon && !@loading} name={@icon} class={icon_size(@size)} />
      {render_slot(@inner_block)}
      <.icon :if={@icon_right} name={@icon_right} class={icon_size(@size)} />
    </button>
    """
  end

  def button(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      href={@href}
      method={@method}
      class={button_class(@variant, @size, @class)}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class={icon_size(@size)} />
      {render_slot(@inner_block)}
      <.icon :if={@icon_right} name={@icon_right} class={icon_size(@size)} />
    </.link>
    """
  end

  defp button_class(variant, size, class),
    do: ["fui-btn", "fui-btn--#{variant}", size == "sm" && "fui-btn--sm", class]

  defp icon_size("sm"), do: "w-4 h-4"
  defp icon_size("md"), do: "w-5 h-5"

  @doc """
  The one labelled form control: label, control, hint, errors.

  Every form field goes through here, so a control's box — its size, focus
  ring and border — is one decision rather than one per template. A
  `Phoenix.HTML.FormField` may be passed; the operator screens pass plain
  attributes, since their forms are maps against the controller.

  `type="select"` renders a native `<select>`; `type="checkbox"` a boolean.
  `data-testid` rides the global attributes through to the control itself.

      <.input type="textarea" name="start[init_values]" label="Init values"
        hint="JSON, optional" mono value={@form["init_values"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               range search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []

  attr :hint, :string,
    default: nil,
    doc: "a constraint or an optional meaning, rendered with the field rather than beside it"

  attr :mono, :boolean, default: false, doc: "true for a field holding an identifier or JSON"

  attr :compact, :boolean,
    default: false,
    doc: "true for a toolbar filter, which sits tighter than a field in a form"

  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  # A field given only its name still gets an id, so its label names it.
  def input(%{id: nil, name: name} = assigns) when is_binary(name) do
    assigns
    |> assign(:id, name |> String.replace(~r/[\[\]]+/, "_") |> String.trim("_"))
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fui-field">
      <label class="fui-check">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          {@rest}
        />
        {@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fui-field">
      <.label :if={@label} for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={[@mono && "fui-input--mono", @compact && "fui-input--compact"]}
        aria-invalid={@errors != [] && "true"}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint} class="fui-hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fui-field">
      <.label :if={@label} for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[@mono && "fui-input--mono"]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="fui-hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="fui-field">
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[@mono && "fui-input--mono", @compact && "fui-input--compact"]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <p :if={@hint} class="fui-hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "A field's label."
  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class="fui-label">{render_slot(@inner_block)}</label>
    """
  end

  @doc "A field's error message."
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="fui-error">
      <.icon name="hero-exclamation-circle-mini" class="h-4 w-4 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  An on/off setting. A button with `role="switch"`, labelled with what it
  switches and reporting its state through `aria-checked`; the click is the
  caller's (`phx-click` and `phx-value-*` ride the global attributes).

      <.switch checked={source.enabled} label={source.name} phx-click="toggle_source"
        phx-value-source={source.name} />
  """
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :show_label, :boolean, default: true
  attr :testid, :string, default: nil
  attr :rest, :global, include: ~w(disabled)

  def switch(assigns) do
    ~H"""
    <button
      type="button"
      role="switch"
      aria-checked={to_string(@checked)}
      aria-label={!@show_label && @label}
      data-testid={@testid}
      class="fui-switch"
      {@rest}
    >
      <span class="fui-switch-track" aria-hidden="true"></span>
      <span :if={@show_label} class="fui-switch-label">{@label}</span>
    </button>
    """
  end

  @doc ~S"""
  An exclusive set of choices. Each option is a link (`patch` or `navigate`)
  or a button (`click`, sending `value`), and the chosen one
  is marked.

      <.segmented label="Scope">
        <:option patch={~p"/relays"} current={@scope == nil}>All namespaces</:option>
        <:option patch={~p"/namespaces/#{@ns}/relays"} current={@scope != nil}>{@ns}</:option>
      </.segmented>
  """
  attr :label, :string, required: true
  attr :testid, :string, default: nil

  slot :option, required: true do
    attr :current, :boolean
    attr :patch, :string
    attr :navigate, :string
    attr :click, :string
    attr :value, :string
    attr :testid, :string
  end

  def segmented(assigns) do
    ~H"""
    <div class="fui-segmented" role="group" aria-label={@label} data-testid={@testid}>
      <%= for option <- @option do %>
        <.link
          :if={option[:patch] || option[:navigate]}
          patch={option[:patch]}
          navigate={option[:navigate]}
          aria-current={option[:current] && "true"}
          data-testid={option[:testid]}
          class="fui-segment"
        >
          {render_slot(option)}
        </.link>
        <button
          :if={!(option[:patch] || option[:navigate])}
          type="button"
          phx-click={option[:click]}
          value={option[:value]}
          aria-pressed={to_string(option[:current] || false)}
          data-testid={option[:testid]}
          class="fui-segment"
        >
          {render_slot(option)}
        </button>
      <% end %>
    </div>
    """
  end

  @doc """
  A picker that chooses one value for a form, with a filter box once the
  choice is long.

  The value lives in a hidden input under the enclosing form's own name, so the
  form's `phx-change` fires with exactly the params a `select` would send.
  Opening, closing, filtering and the keyboard are the console's popover
  behaviour (`assets/js/app.js`).

      <.combobox id="ns" name="filters[namespace]" value={@filters["namespace"]} prompt="All">
        <:option value="">All</:option>
        <:option :for={ns <- @namespaces} value={ns}>{ns}</:option>
      </.combobox>
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :prompt, :string, default: nil, doc: "shown when the value matches no option"
  attr :testid, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :searchable, :boolean, default: nil, doc: "defaults to true past eight options"
  attr :class, :string, default: nil

  slot :option, required: true do
    attr :value, :string, required: true
  end

  def combobox(assigns) do
    value = to_string(assigns.value || "")

    assigns =
      assigns
      |> assign(:value, value)
      |> assign(:chosen, Enum.find(assigns.option, &(&1.value == value)))
      |> assign(:searchable, assigns.searchable || length(assigns.option) > 8)

    ~H"""
    <div class={["fui-field", @class]}>
      <.label :if={@label} for={"#{@id}-trigger"}>{@label}</.label>
      <div id={@id} class="fui-combobox" data-fui-pop>
        <input type="hidden" id={"#{@id}-value"} name={@name} value={@value} />
        <button
          type="button"
          id={"#{@id}-trigger"}
          class="fui-combobox-trigger"
          data-fui-pop-trigger
          data-testid={@testid}
          aria-haspopup="listbox"
          aria-expanded="false"
          disabled={@disabled}
          phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        >
          <span class="flex-1 truncate text-left">
            {(@chosen && render_slot(@chosen)) || @prompt}
          </span>
          <.icon name="hero-chevron-down-mini" class="w-4 h-4 shrink-0" />
        </button>
        <div
          class="fui-popover"
          data-fui-pop-panel
          role="listbox"
          hidden
          phx-mounted={JS.ignore_attributes(["hidden", "style"])}
        >
          <input
            :if={@searchable}
            type="search"
            class="fui-combobox-search fui-input--compact"
            placeholder="Filter"
            aria-label="Filter the choices"
            data-fui-filter
          />
          <button
            :for={option <- @option}
            type="button"
            role="option"
            aria-checked={to_string(option.value == @value)}
            data-testid={@testid && "#{@testid}-#{option.value}"}
            data-fui-pop-item
            phx-click={
              JS.set_attribute({"value", option.value}, to: "##{@id}-value")
              |> JS.dispatch("change", to: "##{@id}-value", bubbles: true)
            }
            class="fui-option"
          >
            <.icon name="hero-check-mini" class="fui-option-check w-4 h-4" />
            <span class="truncate">{render_slot(option)}</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  A field whose values the controller enumerates: offered as a selection, and
  typed only when the controller could not answer.

  Three states, because a picker over a set the operator cannot see is worse
  than a text box: the set is known and offered, the set is known to be empty
  and says so with the control disabled, or the listing was refused and the
  field accepts a typed value with the refusal stated. Callers supply the
  wording for the empty case, since "no factories are registered here" and "no
  namespaces are reachable" are different facts.
  """
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :options, :list, default: [], doc: "`{label, value}` pairs the controller reported"
  attr :prompt, :string, default: nil, doc: "shown above a non-empty set"
  attr :empty, :string, required: true, doc: "what to say when the reported set is empty"
  attr :error, :any, default: nil, doc: "the refusal, when the listing could not be read"
  attr :hint, :string, default: nil
  attr :mono, :boolean, default: false
  attr :placeholder, :string, default: nil, doc: "for the typed fallback"
  attr :testid, :string, required: true

  def enumerated_field(%{error: nil} = assigns) do
    ~H"""
    <.input
      type="select"
      name={@name}
      label={@label}
      value={@value}
      prompt={(@options == [] && @empty) || @prompt}
      options={@options}
      hint={@hint}
      mono={@mono}
      disabled={@options == []}
      data-testid={@testid}
    />
    """
  end

  def enumerated_field(assigns) do
    ~H"""
    <.input
      type="text"
      name={@name}
      label={@label}
      value={@value}
      placeholder={@placeholder}
      hint={"The choices could not be read (#{error_message(@error)}) — type a value instead."}
      mono={@mono}
      data-testid={@testid}
    />
    """
  end

  @doc "A short label: a factory, a hook, a key."
  attr :mono, :boolean, default: false
  attr :testid, :string, default: nil
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def chip(assigns) do
    ~H"""
    <span class={["fui-chip", @mono && "fui-chip--mono"]} data-testid={@testid} title={@title}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A controller value as a badge: its words from `FlezhaUiWeb.Words`, painted
  in its tone. Health also carries a shape per verdict, so it is never told by
  colour alone, and the attributes the browser tests read (`health-badge`,
  `data-health`).

      <.state_badge value={row.health} />
      <.state_badge kind={:readiness} value={@boot.readiness} />
      <.state_badge value={:suspended} count={3} />
  """
  attr :kind, :atom, default: :health
  attr :value, :any, required: true
  attr :count, :any, default: nil, doc: "how many carry this value, for a rollup"
  attr :testid, :string, default: nil
  attr :class, :string, default: nil
  attr :title, :string, default: nil, doc: "what the state means, as a tooltip"

  def state_badge(assigns) do
    assigns = assign(assigns, :said, Words.say(assigns.kind, assigns.value))

    ~H"""
    <span
      data-testid={@testid || (@kind == :health && "health-badge")}
      data-health={@kind == :health && to_string(@value || :unknown)}
      data-state={@kind != :health && state_attr(@value)}
      class={["fui-badge", tone_class(@said.tone), @class]}
      title={@title}
    >
      <span :if={@said[:shape]} class="fui-shape" data-shape={@said.shape} aria-hidden="true"></span>
      <span :if={not is_nil(@count)} class="fui-badge-count">{@count}</span>
      {@said.text}
    </span>
    """
  end

  # A value the browser tests can read back; a compound one is named by its words.
  defp state_attr(value) when is_atom(value) or is_binary(value), do: to_string(value)
  defp state_attr(_compound), do: nil

  defp tone_class(:positive), do: "fui-badge--positive"
  defp tone_class(:warning), do: "fui-badge--warning"
  defp tone_class(:negative), do: "fui-badge--negative"
  defp tone_class(_neutral), do: nil

  @doc """
  A value's words in its tone, for a word inside a sentence; `lower` sets it
  in lower case mid-sentence.
  """
  attr :kind, :atom, required: true
  attr :value, :any, required: true
  attr :lower, :boolean, default: false
  attr :testid, :string, default: nil

  def said(assigns) do
    assigns = assign(assigns, :said, Words.say(assigns.kind, assigns.value))

    ~H"""
    <%!-- Inline in a sentence: whitespace inside would show before its punctuation. --%>
    <span class={"fui-tone-#{@said.tone}"} data-testid={@testid} phx-no-format>{if @lower, do: String.downcase(@said.text), else: @said.text}</span>
    """
  end

  @doc """
  A namespace's health as one strip of segments, each sized by its count and
  painted in its verdict's tone.
  """
  attr :counts, :list, required: true, doc: "`{health, count}` pairs"
  attr :testid, :string, default: nil

  def strip(assigns) do
    ~H"""
    <span class="fui-strip" data-testid={@testid} aria-hidden="true">
      <span
        :for={{health, count} <- @counts}
        :if={count > 0}
        class="fui-strip-part"
        data-tone={Words.tone(:health, health)}
        style={"flex-grow: #{count}"}
      >
      </span>
    </span>
    """
  end

  # ======================================================================
  # Data display
  # ======================================================================

  @doc ~S"""
  A listing: sticky header, row hover, a health edge bar, figures
  right-aligned in mono, and one row menu.

  `row_tone` paints a row's leading edge; `row_activate` makes a row a control
  — a JS command run on click and on Enter, which is how a row opens its
  inspector. A `:col` marked `num` is a figure.

      <.grid id="relays" rows={@rows} row_id={&"relay-#{&1.id}"} row_tone={&tone/1}>
        <:col :let={row} label="Relay">{row.id}</:col>
        <:col :let={row} label="Rate" num>{row.rate}</:col>
        <:menu :let={row}><.row_menu id={"menu-#{row.id}"}>...</.row_menu></:menu>
      </.grid>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :testid, :string, default: nil
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_testid, :any, default: nil, doc: "the function for a row's test id"
  attr :row_tone, :any, default: nil, doc: "the function for a row's tone, or nil for none"
  attr :row_activate, :any, default: nil, doc: "the function for a row's JS command, or nil"
  attr :row_selected, :any, default: nil, doc: "the function telling whether a row is selected"
  attr :row_label, :any, default: nil, doc: "the function for an activatable row's name"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :menu slots"

  slot :col, required: true do
    attr :label, :string
    attr :num, :boolean
    attr :class, :string
  end

  slot :menu, doc: "the row's menu, in the last column"
  slot :foot

  def grid(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="fui-grid-wrap">
      <table class="fui-grid" data-testid={@testid}>
        <thead>
          <tr>
            <th :for={col <- @col} class={col[:num] && "fui-cell-num"}>{col[:label]}</th>
            <th :if={@menu != []} class="fui-cell-menu"><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            data-testid={@row_testid && @row_testid.(row)}
            data-tone={@row_tone && @row_tone.(row)}
            data-activate={@row_activate && @row_activate.(row) && "true"}
            aria-selected={@row_selected && to_string(@row_selected.(row))}
            aria-label={@row_label && @row_label.(row)}
            tabindex={@row_activate && @row_activate.(row) && "0"}
            phx-click={@row_activate && @row_activate.(row)}
            phx-keydown={@row_activate && @row_activate.(row)}
            phx-key={@row_activate && "Enter"}
          >
            <td :for={col <- @col} class={[col[:num] && "fui-cell-num", col[:class]]}>
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@menu != []} class="fui-cell-menu" phx-click={JS.dispatch("fui:menu")}>
              {render_slot(@menu, @row_item.(row))}
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@foot != []} class="fui-grid-foot">{render_slot(@foot)}</div>
    </div>
    """
  end

  @doc """
  A row's actions, behind one menu control, so a destructive action never sits
  beside a benign one. Each item is a link (`navigate`, `patch`) or a button
  (`click` with `values` as `phx-value-*`); `danger` marks the one that
  destroys, which opens its screen's confirmation rather than acting.
  """
  attr :id, :string, required: true
  attr :label, :string, default: "Actions"
  attr :testid, :string, default: nil

  slot :item, required: true do
    attr :click, :string
    attr :values, :map
    attr :navigate, :string
    attr :patch, :string
    attr :href, :string
    attr :danger, :boolean
    attr :testid, :string
    attr :icon, :string
  end

  def row_menu(assigns) do
    ~H"""
    <.popover id={@id} label={@label} testid={@testid} align="end">
      <:trigger><.icon name="hero-ellipsis-horizontal" class="w-5 h-5" /></:trigger>
      <%= for item <- @item do %>
        <.link
          :if={item[:navigate] || item[:patch] || item[:href]}
          navigate={item[:navigate]}
          patch={item[:patch]}
          href={item[:href]}
          data-testid={item[:testid]}
          data-fui-pop-item
          class={["fui-menu-item", item[:danger] && "fui-menu-item--danger"]}
        >
          <.icon :if={item[:icon]} name={item.icon} class="w-4 h-4" />
          {render_slot(item)}
        </.link>
        <button
          :if={!(item[:navigate] || item[:patch] || item[:href])}
          type="button"
          phx-click={item[:click]}
          {values_attrs(item[:values] || %{})}
          data-testid={item[:testid]}
          data-fui-pop-item
          class={["fui-menu-item", item[:danger] && "fui-menu-item--danger"]}
        >
          <.icon :if={item[:icon]} name={item.icon} class="w-4 h-4" />
          {render_slot(item)}
        </button>
      <% end %>
    </.popover>
    """
  end

  defp values_attrs(values) do
    Map.new(values, fn {key, value} -> {"phx-value-#{key}", value} end)
  end

  @doc """
  One labelled figure in a `<dl class="fui-facts">` of them — the shape every
  set of facts is made of. `tone` paints the value in an outcome's ink; `mono`
  sets it as an identifier or figure.
  """
  attr :label, :any, required: true
  attr :testid, :string, default: nil
  attr :tone, :atom, default: nil, values: [nil, :positive, :warning, :negative, :neutral]
  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  def stat(assigns) do
    ~H"""
    <div class="fui-fact">
      <dt>{@label}</dt>
      <dd
        data-testid={@testid}
        class={[@tone && "fui-tone-#{@tone}", @mono && "fui-ident"]}
      >
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  @doc """
  A figure that is marked for a moment when it changes between refreshes.

  The mark is the client's (`FlzChange`): it compares `value` with the last
  one it saw and sets `data-changed`, which the server patch leaves alone. It
  carries no state, and the new value is always printed.
  """
  attr :id, :string, required: true
  attr :value, :any, required: true
  attr :testid, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block

  def live_value(assigns) do
    ~H"""
    <span
      id={@id}
      phx-hook="FlzChange"
      phx-mounted={JS.ignore_attributes(["data-changed"])}
      data-value={to_string(@value)}
      data-testid={@testid}
      class={@class}
      phx-no-format
    >{if @inner_block != [], do: render_slot(@inner_block), else: @value}</span>
    """
  end

  @doc """
  A rate's recent history as a line: the samples this console measured,
  oldest first. Fewer than two samples draw nothing rather than a flat line.

  Samples are numbers, or maps read at `key`.
  """
  attr :samples, :list, required: true
  attr :key, :atom, default: :in
  attr :width, :integer, default: 72
  attr :height, :integer, default: 20
  attr :testid, :string, default: "sparkline"
  attr :label, :string, default: "Rate history"

  def sparkline(assigns) do
    values = Enum.map(assigns.samples, &sample_value(&1, assigns.key))

    assigns =
      assigns
      |> assign(:values, values)
      |> assign(:points, spark_points(values, assigns.width, assigns.height))

    ~H"""
    <svg
      :if={length(@values) >= 2}
      class="fui-spark"
      viewBox={"0 0 #{@width} #{@height}"}
      width={@width}
      height={@height}
      role="img"
      aria-label={"#{@label}: #{length(@values)} samples, peak #{Enum.max(@values)}/s"}
      data-testid={@testid}
      data-samples={length(@values)}
    >
      <polyline points={@points} />
    </svg>
    """
  end

  defp sample_value(sample, _key) when is_number(sample), do: sample
  defp sample_value(sample, key) when is_map(sample), do: Map.get(sample, key) || 0
  defp sample_value(_sample, _key), do: 0

  @doc """
  The polyline points for `values` in a `width` × `height` box, oldest first,
  scaled to the peak. Public so a server-drawn SVG (the Home map) draws its
  lane sparklines with the same arithmetic.
  """
  def spark_points(values, width, height) do
    count = length(values)
    peak = Enum.max([0 | values])
    step = if count > 1, do: width / (count - 1), else: 0.0
    scale = if peak > 0, do: (height - 2) / peak, else: 0.0

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, index} ->
      "#{Float.round(index * step, 1)},#{Float.round(height - 1 - value * scale, 1)}"
    end)
  end

  @doc "A share of a limit, as a bar: a quota against its ceiling."
  attr :value, :any, required: true
  attr :max, :any, required: true
  attr :tone, :atom, default: nil, values: [nil, :warning, :negative]
  attr :label, :string, required: true
  attr :testid, :string, default: nil

  def meter(assigns) do
    value = assigns.value || 0
    max = max(assigns.max || 1, 1)
    assigns = assign(assigns, :percent, min(100, round(value * 100 / max)))

    ~H"""
    <span
      class="fui-meter"
      role="meter"
      aria-label={@label}
      aria-valuenow={@value || 0}
      aria-valuemin="0"
      aria-valuemax={@max}
      data-tone={@tone}
      data-testid={@testid}
    >
      <span class="fui-meter-fill" style={"width: #{@percent}%"}></span>
    </span>
    """
  end

  @doc """
  A payload, a schema, a token or help text, in mono. Long lines wrap instead
  of scrolling sideways.
  """
  attr :id, :string, default: nil
  attr :testid, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def code_block(assigns) do
    ~H"""
    <pre id={@id} data-testid={@testid} class={["fui-code", @class]}>{render_slot(@inner_block)}</pre>
    """
  end

  @doc "A key, as the keyboard labels it."
  slot :inner_block, required: true

  def kbd(assigns) do
    ~H"""
    <kbd class="fui-kbd">{render_slot(@inner_block)}</kbd>
    """
  end

  @doc """
  An identifier. One longer than 16 characters reads as `…` and its last 7;
  its full value is its accessible name and tooltip, and activating it copies
  the full value. `full` keeps it whole — a relay id and a namespace name are
  always shown in full.

      <.ident value="default_58efe7505741" />   <%!-- …7505741 --%>
      <.ident value={@relay_id} full />
  """
  attr :value, :any, required: true
  attr :full, :boolean, default: false
  attr :copy, :boolean, default: nil, doc: "defaults to true when the value is shortened"
  attr :testid, :string, default: nil
  attr :class, :string, default: nil

  def ident(assigns) do
    text = to_string(assigns.value)
    short? = not assigns.full and String.length(text) > 16

    assigns =
      assign(assigns,
        text: text,
        shown: if(short?, do: "…" <> String.slice(text, -7, 7), else: text),
        copy: if(is_nil(assigns.copy), do: short?, else: assigns.copy)
      )

    ~H"""
    <button
      :if={@copy}
      type="button"
      class={["fui-ident", @class]}
      title={@text}
      aria-label={@text}
      data-fui-copy={@text}
      data-testid={@testid}
    >
      {@shown}
    </button>
    <span :if={!@copy} class={["fui-ident", @class]} data-testid={@testid}>{@shown}</span>
    """
  end

  @doc """
  A flezha term where a screen first uses it: dotted, with its glossary
  definition shown on hover and on keyboard focus, as its accessible
  description. Activating it opens the screen's help.

      <.term key="runner" />          <%!-- renders "runner" --%>
      <.term key="relay">relays</.term>
  """
  attr :key, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block

  def term(assigns) do
    entry = Glossary.term!(assigns.key)

    assigns =
      assigns
      |> assign(:entry, entry)
      |> assign(:tip_id, assigns.id || "term-#{String.replace(assigns.key, " ", "-")}")

    ~H"""
    <%!-- Inline in a sentence: whitespace inside would show before its punctuation. --%>
    <span class="fui-tip-host" phx-no-format><button
        type="button"
        class="fui-term"
        aria-describedby={@tip_id}
        data-fui-help-open
        data-testid={"term-#{@entry.key}"}
      >{if @inner_block != [], do: render_slot(@inner_block), else: @entry.key}</button><span
        role="tooltip"
        id={@tip_id}
        class="fui-tooltip"
      ><span class="fui-tooltip-term">{@entry.name}</span>{@entry.definition}</span></span>
    """
  end

  @doc """
  A hint for a control, shown on hover and focus. The control inside should
  carry `aria-describedby` naming `id`.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  slot :inner_block, required: true

  def tooltip(assigns) do
    ~H"""
    <span class="fui-tip-host" phx-no-format>{render_slot(@inner_block)}<span role="tooltip" id={@id} class="fui-tooltip">{@text}</span></span>
    """
  end

  @doc """
  A "?" beside a heading or a control that explains it in plain words when
  clicked, and stays open while it is read.

      <.help_tip id="help-quotas" label="What quotas are">
        A quota caps how many relays the namespace may run.
      </.help_tip>
  """
  attr :id, :string, required: true
  attr :label, :string, default: "What is this?"
  attr :align, :string, default: "start", values: ~w(start end)
  slot :inner_block, required: true

  def help_tip(assigns) do
    ~H"""
    <.popover
      id={@id}
      testid={@id}
      label={@label}
      role="dialog"
      align={@align}
      trigger_class="fui-help-tip"
      panel_class="fui-help-panel"
    >
      <:trigger><.icon name="hero-question-mark-circle" class="w-5 h-5" /></:trigger>
      {render_slot(@inner_block)}
    </.popover>
    """
  end

  # ======================================================================
  # Statements
  # ======================================================================

  @doc """
  A short explanation sitting above or beside content: `:info` for a state that
  is not a fault, `:error` for a failure.
  """
  attr :kind, :atom, default: :info, values: [:info, :error]
  attr :icon, :string, default: nil
  attr :testid, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def notice(assigns) do
    assigns =
      assign_new(assigns, :resolved_icon, fn -> notice_icon(assigns.kind, assigns.icon) end)

    ~H"""
    <div
      role={@kind == :error && "alert"}
      data-testid={@testid}
      class={["fui-note", @kind == :error && "fui-note--error", @class]}
    >
      <.icon name={@resolved_icon} class="fui-note-icon w-5 h-5" />
      <div class="min-w-0 space-y-1">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  defp notice_icon(_kind, icon) when is_binary(icon), do: icon
  defp notice_icon(:error, _icon), do: "hero-exclamation-triangle"
  defp notice_icon(:info, _icon), do: "hero-information-circle"

  @doc """
  What a listing or a region says when it holds nothing: one sentence saying
  what would appear and what produces it, and the action that produces it
  when the operator may take it.

      <.empty_state icon="hero-clock" testid="schedule-empty">
        A schedule starts a relay from a factory on a cron expression.
        <:action><.button phx-click="open_form">New schedule</.button></:action>
      </.empty_state>
  """
  attr :icon, :string, required: true
  attr :testid, :string, default: nil
  slot :inner_block, required: true
  slot :detail, doc: "a second line, for what is still to know"
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div data-testid={@testid} class="fui-empty">
      <.icon name={@icon} class="fui-empty-icon w-6 h-6" />
      <p class="fui-empty-text">{render_slot(@inner_block)}</p>
      <p :if={@detail != []} class="fui-empty-text">{render_slot(@detail)}</p>
      <div :if={@action != []} class="fui-empty-actions">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc """
  What a screen shows in the shape of what it will show, before its first
  read lands — never an empty table or an empty state the data has not
  confirmed.
  """
  attr :rows, :integer, default: 4
  attr :testid, :string, default: "skeleton"

  def skeleton(assigns) do
    ~H"""
    <div class="fui-skeleton-rows" data-testid={@testid} aria-busy="true" aria-label="Loading">
      <span
        :for={index <- 1..@rows}
        class="fui-skeleton"
        style={"width: #{100 - rem(index * 17, 40)}%"}
      >
      </span>
    </div>
    """
  end

  @doc """
  Renders a banner for a normalised `FlezhaUi.Service.NodeManager` error.

  Renders nothing when `error` is `nil`, so a screen can pass its last call
  result unconditionally. A controller error links to its code's family in
  core's errors reference; a condition only this node sees has no code there
  and no link. A diagnosis finding has the same shape and renders here too,
  as `:info` when it is only a note.
  """
  attr :error, :any, default: nil, doc: "a normalised NodeManager error, or nil"
  attr :class, :string, default: nil
  attr :kind, :atom, default: :error, values: [:info, :error]

  attr :action, :string,
    default: nil,
    doc: "what was refused, named in a refusal — \"read the audit log\", \"stop the relay\""

  def runtime_error(assigns) do
    assigns =
      assigns
      |> assign(:error, assigns.error && NodeManager.error(assigns.error))
      |> assign(:settings_link?, settings_link?(assigns.error))

    ~H"""
    <.notice :if={@error} kind={@kind} testid="runtime-error" class={@class}>
      <p>{error_message(@error, @action)}</p>
      <p :if={@error.hint} class="text-xs" data-testid="runtime-error-hint">{@error.hint}</p>
      <a
        :if={reference_url(@error.code)}
        href={reference_url(@error.code)}
        target="_blank"
        rel="noopener noreferrer"
        data-testid="runtime-error-reference"
        class="block text-xs"
      >
        What {@error.code} means
      </a>
      <.link :if={@settings_link?} navigate={~p"/users/settings"}>
        Store a flezha token in settings.
      </.link>
    </.notice>
    """
  end

  # Core's errors reference has one section per family — the code before its
  # first dot — and no anchor per code, so the family is the deepest link.
  defp reference_url("ui." <> _), do: nil

  defp reference_url(code) when is_binary(code) do
    [family | _] = String.split(code, ".", parts: 2)
    "#{Application.fetch_env!(:flezha_ui, :core_docs_url)}/errors.html##{family}"
  end

  defp reference_url(_code), do: nil

  @doc """
  A form's error: its own validation message as written, or what a call
  answered rendered as `runtime_error/1` does.
  """
  attr :error, :any, default: nil, doc: "a validation message, a call's error, or nil"
  attr :action, :string, default: nil
  attr :testid, :string, required: true

  def form_error(assigns) do
    ~H"""
    <.notice :if={is_binary(@error)} kind={:error} testid={@testid}>
      {@error}
    </.notice>
    <div :if={@error && !is_binary(@error)} data-testid={@testid}>
      <.runtime_error error={@error} action={@action} />
    </div>
    """
  end

  # A missing identity is remedied in settings; every other refusal is a role
  # the operator has to be granted elsewhere.
  defp settings_link?(nil), do: false

  defp settings_link?(error),
    do: NodeManager.error(error).code in ~w(authz.principal_not_bound authz.no_role_binding)

  @doc """
  One line for an error a `NodeManager` call answered: the controller's own
  message and its code, and for a refusal the action refused. A condition only
  this node sees — no controller, a timeout — is stated in words alone.

  Public because a form states an error inline rather than as a banner.
  """
  def error_message(error, action \\ nil)

  # A condition only this node sees has no code to name, unless it is a refusal.
  def error_message(%{code: "ui." <> _, class: class} = error, action) when class != :denied,
    do: error_text(error, action)

  def error_message(%{code: code, message: _} = error, action),
    do: "#{error_text(error, action)} (#{code})"

  def error_message(error, action), do: error_message(NodeManager.error(error), action)

  defp error_text(%{class: :denied, message: message}, action),
    do: "The controller refused #{action || "this call"}: #{message}"

  defp error_text(%{message: message}, _action), do: message

  @doc """
  Scrolls the element with `id` into view and marks it briefly, for a result
  that renders away from the control that asked for it. The `fui:reveal`
  listener in app.js does the scrolling.
  """
  def reveal(socket, id), do: Phoenix.LiveView.push_event(socket, "fui:reveal", %{id: id})

  @doc """
  The controller's authorization posture, as a notice. Renders nothing when
  there is nothing an operator needs to act on: an open controller, or an
  enforced one with a bound principal.
  """
  attr :status, :map, required: true, doc: "a `NodeManager.authz_status/1` map"

  def authz_banner(assigns) do
    ~H"""
    <.notice
      :if={@status.posture == :bootstrap_pending}
      kind={:error}
      testid="authz-bootstrap-pending"
      class="mb-6"
    >
      Authorization is enforced on this controller but has not been claimed. Run
      <code>flz auth bootstrap &lt;token&gt;</code>
      on the controller to claim it; until then every operator verb is refused.
    </.notice>

    <.notice
      :if={@status.posture == :enforced and is_nil(@status.principal)}
      kind={:error}
      testid="authz-unbound"
      class="mb-6"
    >
      <span :if={@status.token?}>
        The flezha token this console presents did not bind an identity — {@status.reason &&
          error_message(@status.reason)}
      </span>
      <span :if={!@status.token?}>No flezha token is bound to this console.</span>
      Reads of the audit log and observability, and every mutation, will be refused.
      <.link navigate={~p"/users/settings"}>Store a token in settings.</.link>
    </.notice>
    """
  end

  # ======================================================================
  # Overlays
  # ======================================================================

  @doc """
  A trigger and a floating panel: an account menu, a namespace switcher, a
  row's actions. Opening, closing, the keyboard and closing on a chosen item
  are the console's popover behaviour, which works on plain controller pages
  too; the panel's open state survives a server patch.
  """
  attr :id, :string, required: true
  attr :testid, :string, default: nil
  attr :label, :string, default: nil, doc: "what the trigger is called, for a screen reader"
  attr :align, :string, default: "start", values: ~w(start end)
  attr :trigger_class, :string, default: "fui-iconbtn"
  attr :panel_class, :string, default: nil
  attr :role, :string, default: "menu"

  slot :trigger, required: true
  slot :inner_block, required: true

  def popover(assigns) do
    ~H"""
    <div id={@id} class="fui-pop" data-fui-pop>
      <button
        type="button"
        class={@trigger_class}
        data-fui-pop-trigger
        data-testid={@testid}
        aria-label={@label}
        aria-haspopup={@role}
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        {render_slot(@trigger)}
      </button>
      <div
        class={["fui-popover", "fui-popover--#{@align}", @panel_class]}
        role={@role}
        data-fui-pop-panel
        hidden
        phx-mounted={JS.ignore_attributes(["hidden", "style"])}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  An inspector drawer: beside the content at desktop width, a full sheet at
  phone width. Focus moves in when it opens and returns to the opener when it
  closes; Tab cycles inside it and Escape closes it. `on_close` is the event
  every way of closing sends.
  """
  attr :id, :string, required: true
  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :on_close, :string, required: true
  attr :testid, :string, default: "inspector"
  slot :inner_block, required: true
  slot :actions

  def drawer(assigns) do
    ~H"""
    <div
      id={@id}
      class="fui-drawer"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      data-testid={@testid}
      phx-hook="FlzFocus"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <div class="fui-scrim" phx-click={@on_close}></div>
      <section class="fui-drawer-panel">
        <header class="fui-drawer-head">
          <div class="min-w-0 space-y-1">
            <p class="fui-eyebrow">{@eyebrow}</p>
            <h2 id={"#{@id}-title"} class="fui-drawer-title">{@title}</h2>
          </div>
          <button
            type="button"
            class="fui-iconbtn"
            phx-click={@on_close}
            aria-label="Close"
            data-testid="inspector-close"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </header>
        <div class="fui-drawer-body">
          {render_slot(@inner_block)}
          <div :if={@actions != []} class="flex flex-wrap gap-2">{render_slot(@actions)}</div>
        </div>
      </section>
    </div>
    """
  end

  @doc """
  The panel every dialog sits in, over a scrim. A `:title` slot heads it and,
  with `on_close`, gives it the dismiss control and closes it on Escape. Focus
  moves in when it opens and returns when it closes.

      <.dialog :if={@open} testid="start-modal" size="form" on_close="close_start">
        <:title>Start a relay</:title>
        ...
      </.dialog>
  """
  attr :id, :string, default: nil, doc: "defaults to the test id"
  attr :testid, :string, default: nil

  attr :size, :string,
    default: "confirm",
    values: ~w(confirm form wide),
    doc: "what the dialog is for; the width follows from it"

  attr :on_close, :string,
    default: nil,
    doc: "the event the dismiss control and Escape send; without it there is no control"

  attr :close_testid, :string, default: nil
  slot :title
  slot :actions, doc: "controls in the dialog foot, right-aligned"
  slot :inner_block, required: true

  def dialog(assigns) do
    assigns = assign(assigns, :id, assigns.id || assigns.testid || "dialog")

    ~H"""
    <div
      id={@id}
      class="fui-dialog"
      phx-hook="FlzFocus"
      phx-window-keydown={@on_close}
      phx-key={@on_close && "Escape"}
    >
      <div class="fui-scrim"></div>
      <div
        data-testid={@testid}
        role="dialog"
        aria-modal="true"
        aria-labelledby={@title != [] && "#{@id}-title"}
        class={["fui-dialog-panel", "fui-dialog-panel--#{@size}"]}
      >
        <div :if={@title != []} class="fui-dialog-head">
          <h2 id={"#{@id}-title"} class="fui-dialog-title">{render_slot(@title)}</h2>
          <button
            :if={@on_close}
            type="button"
            phx-click={@on_close}
            data-testid={@close_testid}
            class="fui-iconbtn"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
        <div class="fui-dialog-body">{render_slot(@inner_block)}</div>
        <div :if={@actions != []} class="fui-dialog-foot">{render_slot(@actions)}</div>
      </div>
    </div>
    """
  end

  @doc """
  A dialog asking the operator to confirm an action before it happens, used
  for every irreversible verb so they all ask the same way. `values` are sent
  with the confirm click; Escape and Cancel send `on_cancel`.
  """
  attr :title, :string, required: true
  attr :confirm_label, :string, required: true
  attr :on_confirm, :string, required: true
  attr :on_cancel, :string, required: true
  attr :values, :map, default: %{}
  attr :variant, :string, default: "danger", values: ~w(danger primary)
  attr :testid, :string, default: nil
  attr :cancel_testid, :string, default: nil
  attr :confirm_testid, :string, default: nil
  slot :inner_block, required: true

  def confirm_dialog(assigns) do
    ~H"""
    <.dialog testid={@testid} size="confirm" on_close={@on_cancel}>
      <:title>{@title}</:title>
      <p>{render_slot(@inner_block)}</p>
      <:actions>
        <.button variant="ghost" phx-click={@on_cancel} data-testid={@cancel_testid}>
          Cancel
        </.button>
        <.button
          variant={@variant}
          phx-click={@on_confirm}
          {values_attrs(@values)}
          data-testid={@confirm_testid}
        >
          {@confirm_label}
        </.button>
      </:actions>
    </.dialog>
    """
  end

  @doc """
  The messages a screen has for the operator, as toasts stacked at the bottom
  right — below the header's layer, so they never cover its controls. An
  informational toast leaves after five seconds; an error stays until it is
  dismissed. Each is announced and dismissible from the keyboard.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="fui-toasts" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Lost the connection")}
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {gettext("Trying to reconnect")}
        <.icon name="hero-arrow-path" class="fui-spin ml-1 h-3 w-3" />
      </.flash>
      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong")}
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Hang in there while we get back on track")}
        <.icon name="hero-arrow-path" class="fui-spin ml-1 h-3 w-3" />
      </.flash>
    </div>
    """
  end

  @doc "One toast. See `flash_group/1`."
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role={if @kind == :error, do: "alert", else: "status"}
      phx-hook="FlzToast"
      data-kind={@kind}
      data-testid={"toast-#{@kind}"}
      class={["fui-toast", @kind == :error && "fui-toast--error"]}
      {@rest}
    >
      <.icon
        name={if @kind == :error, do: "hero-exclamation-circle", else: "hero-check-circle"}
        class="fui-toast-icon w-5 h-5"
      />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="fui-toast-title">{@title}</p>
        <p>{msg}</p>
      </div>
      <button
        type="button"
        class="fui-iconbtn"
        aria-label={gettext("Dismiss")}
        data-toast-dismiss
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      >
        <.icon name="hero-x-mark" class="h-4 w-4" />
      </button>
    </div>
    """
  end

  # ======================================================================
  # Flows
  # ======================================================================

  @doc """
  A guided flow's layout: its steps across the top, the current step's body,
  and its foot of back and next controls. The flow's state is the caller's;
  this draws where it is.
  """
  attr :steps, :list, required: true, doc: "each step's label, in order"
  attr :current, :integer, required: true, doc: "the current step's index"
  attr :testid, :string, default: "steps"
  slot :inner_block, doc: "the current step's body; a form may keep its fields below instead"
  slot :foot

  def steps(assigns) do
    ~H"""
    <div data-testid={@testid}>
      <ol class="fui-steps" aria-label="Steps">
        <li
          :for={{label, index} <- Enum.with_index(@steps)}
          class="fui-step"
          aria-current={index == @current && "step"}
          data-done={index < @current && "true"}
          data-testid={"#{@testid}-step-#{index}"}
        >
          {label}
        </li>
      </ol>
      <div :if={@inner_block != []} class="fui-steps-body">{render_slot(@inner_block)}</div>
      <div :if={@foot != []} class="fui-steps-foot">{render_slot(@foot)}</div>
    </div>
    """
  end

  # ======================================================================
  # Brand and icons
  # ======================================================================

  @ui_lockup Path.expand(
               "../../../priv/static/images/flezha-ui-badger-line-text-white.svg",
               __DIR__
             )
  @external_resource @ui_lockup

  # The lockup is not square, so its proportions are read from its own viewBox
  # rather than copied by hand.
  @ui_lockup_aspect (case Regex.run(~r/viewBox="\S+ \S+ (\S+) (\S+)"/, File.read!(@ui_lockup)) do
                       [_, width, height] -> "#{width} / #{height}"
                     end)

  @doc """
  The Flezha UI lockup, painted as a mask so it takes the ink of whatever it
  sits on: the chrome's ink in the rail, with the stylebook's own brand
  recipe, and the brand ink on the canvas.
  """
  attr :on, :atom, default: :canvas, values: [:chrome, :canvas]

  def brand_lockup(assigns) do
    ~H"""
    <span class={if @on == :chrome, do: "flz-brand", else: "fui-brand fui-brand--canvas"}>
      <span
        role="img"
        aria-label="Flezha UI"
        class={if @on == :chrome, do: "flz-logo", else: "fui-logo"}
        style={"mask-image: url(#{~p"/images/flezha-ui-badger-line-text-white.svg"}); -webkit-mask-image: url(#{~p"/images/flezha-ui-badger-line-text-white.svg"}); aspect-ratio: #{ui_lockup_aspect()}"}
      >
      </span>
    </span>
    """
  end

  defp ui_lockup_aspect, do: @ui_lockup_aspect

  @doc """
  Renders a [Heroicon](https://heroicons.com): outline by default, `-mini` and
  `-micro` for the 20 and 16 px solid glyphs inside a control.
  """
  attr :name, :string, required: true
  attr :class, :any, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector), do: JS.show(js, to: selector)

  def hide(js \\ %JS{}, selector), do: JS.hide(js, to: selector)

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(FlezhaUiWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(FlezhaUiWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
