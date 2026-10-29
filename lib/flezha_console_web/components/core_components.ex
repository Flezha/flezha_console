defmodule FlezhaConsoleWeb.CoreComponents do
  @moduledoc """
  The console's component kit: one function component per element, each
  drawn by one `fcon-` recipe in `assets/css/console/components.css`.

  A screen composes these and adds layout utilities; it never declares a
  colour, a border, a radius or a padding for one of them. Every component is
  shown in every variant and state on the dev-only `/dev/kit` page.

  Icons are [Heroicons](https://heroicons.com), outline at 16 or 20 px; an
  icon-only control always carries an accessible name.
  """
  use Phoenix.Component
  use Gettext, backend: FlezhaConsoleWeb.Gettext

  # Refusals link to where a token is stored, so the components need routes.
  use Phoenix.VerifiedRoutes,
    endpoint: FlezhaConsoleWeb.Endpoint,
    router: FlezhaConsoleWeb.Router,
    statics: FlezhaConsoleWeb.static_paths()

  alias FlezhaConsole.Format
  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.Glossary
  alias FlezhaConsoleWeb.Live.Sections
  alias FlezhaConsoleWeb.Words
  alias Phoenix.LiveView.JS

  # ======================================================================
  # Page grammar
  # ======================================================================

  @doc """
  The header every screen opens on: the kind of object, its name, one
  sentence about its condition, its actions and its local tabs.

  `crumbs` comes from the shell (`FlezhaConsoleWeb.Layouts.breadcrumbs/1`) and is
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
  attr :tabs, :list, default: [], doc: "`%{label:, path:, current?:, testid:, patch?:}` per view"
  attr :tabs_label, :string, default: "Views"
  attr :headline, :boolean, default: false
  attr :testid, :string, default: "page-header"
  attr :help, :boolean, default: true, doc: "a ? beside the title opening the screen's help"
  slot :sentence
  slot :figures, doc: "a second line of figures in words"
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="fcon-page-header" data-testid={@testid}>
      <.crumbs :if={@crumbs != []} trail={@crumbs} />
      <div class="fcon-page-heading space-y-2">
        <p class="fcon-eyebrow" data-testid="page-eyebrow">{@eyebrow}</p>
        <div class="flex items-center gap-2">
          <h1 class="fcon-title" data-testid="page-title">{@title}</h1>
          <button
            :if={@help}
            type="button"
            class="fcon-help-tip"
            data-fcon-help-open
            aria-label="What this screen is for"
            data-testid="page-help"
          >
            <.icon name="hero-question-mark-circle" class="w-6 h-6" />
          </button>
        </div>
        <p
          :if={@sentence != []}
          class={["fcon-sentence", @headline && "fcon-sentence--headline"]}
          data-testid="page-sentence"
        >
          {render_slot(@sentence)}
        </p>
        <p :if={@figures != []} class="fcon-figures" data-testid="page-figures">
          {render_slot(@figures)}
        </p>
      </div>
      <div :if={@actions != []} class="fcon-page-actions">{render_slot(@actions)}</div>
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
    <nav aria-label="Breadcrumb" data-testid="breadcrumb" class="fcon-crumbs">
      <%= for {crumb, index} <- Enum.with_index(@trail) do %>
        <span :if={index > 0} class="fcon-crumb-sep" aria-hidden="true">/</span>
        <.link :if={crumb.path} navigate={crumb.path}>{crumb.label}</.link>
        <span :if={!crumb.path} aria-current="page">{crumb.label}</span>
      <% end %>
    </nav>
    """
  end

  @doc """
  An object's views, as tabs. Each tab is its own route and navigates, so a
  view holding a live subscription is not mounted while another is read. A
  tab with `patch?` patches instead: one screen showing another of its own
  views, which lets go of what the last one held itself.
  """
  attr :items, :list, required: true, doc: "`%{label:, path:, current?:, testid:, patch?:}`"
  attr :label, :string, default: "Views"
  attr :testid, :string, default: nil

  def tabs(assigns) do
    ~H"""
    <nav class="fcon-tabs" aria-label={@label} data-testid={@testid}>
      <.link
        :for={item <- @items}
        navigate={!item[:patch?] && item.path}
        patch={item[:patch?] && item.path}
        aria-current={item[:current?] && "page"}
        data-testid={item[:testid]}
        class="fcon-tab"
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
  (`FlezhaConsoleWeb.Live.Sections`), so the server renders the truth on first
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
      class={["fcon-section", @flush && "fcon-section--flush", @class]}
    >
      <div class="fcon-section-head">
        <button
          :if={@fold}
          type="button"
          class="fcon-section-toggle"
          aria-expanded={to_string(@open)}
          aria-controls={"#{@id}-body"}
          phx-click="section_toggle"
          phx-value-key={@fold}
          data-testid={"section-toggle-#{@fold}"}
        >
          <.icon name="hero-chevron-right-mini" class="fcon-chevron w-4 h-4" />
          <.section_title digest={@digest}>{render_slot(@title)}</.section_title>
        </button>
        <.section_title :if={!@fold} digest={@digest}>{render_slot(@title)}</.section_title>
        <div :if={@actions != [] or @help} class="fcon-section-actions">
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
          class="fcon-section-body"
        >
          {render_slot(@inner_block)}
        </div>
      <% else %>
        <div class="fcon-section-body">{render_slot(@inner_block)}</div>
      <% end %>
    </section>
    """
  end

  attr :digest, :string, default: nil
  slot :inner_block, required: true

  defp section_title(assigns) do
    ~H"""
    <h2 class="fcon-section-title">
      {render_slot(@inner_block)}
      <span :if={@digest} class="fcon-section-digest" data-testid="section-digest">{@digest}</span>
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
      <.icon :if={@loading} name="hero-arrow-path" class={["fcon-spin", icon_size(@size)]} />
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

  # The stylebook's button, as flezha.com wears it; the primary action is its
  # accent fill.
  defp button_class(variant, size, class),
    do: ["flz-button", "flz-button--#{button_variant(variant)}", "flz-button--#{size}", class]

  defp button_variant("primary"), do: "accent"
  defp button_variant(variant), do: variant

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
    <div class="fcon-field">
      <label class="fcon-check">
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
    <div class="fcon-field">
      <.label :if={@label} for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={[@mono && "fcon-input--mono", @compact && "fcon-input--compact"]}
        aria-invalid={@errors != [] && "true"}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint} class="fcon-hint">{code_names(@hint)}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fcon-field">
      <.label :if={@label} for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[@mono && "fcon-input--mono"]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="fcon-hint">{code_names(@hint)}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="fcon-field">
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[@mono && "fcon-input--mono", @compact && "fcon-input--compact"]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <p :if={@hint} class="fcon-hint">{code_names(@hint)}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "A field's label."
  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class="fcon-label">{render_slot(@inner_block)}</label>
    """
  end

  @doc "A field's error message."
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="fcon-error">
      <.icon name="hero-exclamation-circle-mini" class="h-4 w-4 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  An on/off setting. A button with `role="switch"`, labelled with what it
  switches and reporting its state through `aria-checked`; the click is the
  caller's (`phx-click` and `phx-value-*` ride the global attributes).
  `checked` is `:mixed` for a setting on for only part of what it switches.

      <.switch checked={source.enabled} label={source.name} phx-click="toggle_source"
        phx-value-source={source.name} />
  """
  attr :checked, :any, required: true, values: [true, false, :mixed]
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
      class="fcon-switch"
      {@rest}
    >
      <span class="fcon-switch-track" aria-hidden="true"></span>
      <span :if={@show_label} class="fcon-switch-label">{@label}</span>
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
    <div class="fcon-segmented" role="group" aria-label={@label} data-testid={@testid}>
      <%= for option <- @option do %>
        <.link
          :if={option[:patch] || option[:navigate]}
          patch={option[:patch]}
          navigate={option[:navigate]}
          aria-current={option[:current] && "true"}
          data-testid={option[:testid]}
          class="fcon-segment"
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
          class="fcon-segment"
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

  A choice too long to hold, such as a namespace's relays, is searched on the
  server instead: `search` names the event each debounced query is sent to,
  as `%{"value" => query}`, and the host answers with the first matches as the
  options and how many match in all as `matches`.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :prompt, :string, default: nil, doc: "shown when the value matches no option"
  attr :testid, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :searchable, :boolean, default: nil, doc: "defaults to true past eight options"

  attr :search, :string,
    default: nil,
    doc: "the event a server-searched choice sends its query to"

  attr :query, :string, default: "", doc: "the query the options answer"
  attr :matches, :integer, default: nil, doc: "how many choices match the query in all"
  attr :hint, :string, default: nil
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
      |> assign(
        :searchable,
        !assigns.search and (assigns.searchable || length(assigns.option) > 8)
      )
      |> assign(
        :more,
        max((assigns.matches || 0) - Enum.count(assigns.option, &(&1.value != "")), 0)
      )

    ~H"""
    <div class={["fcon-field", @class]}>
      <.label :if={@label} for={"#{@id}-trigger"}>{@label}</.label>
      <div id={@id} class="fcon-combobox" data-fcon-pop>
        <input type="hidden" id={"#{@id}-value"} name={@name} value={@value} />
        <button
          type="button"
          id={"#{@id}-trigger"}
          class="fcon-combobox-trigger"
          data-fcon-pop-trigger
          data-testid={@testid}
          aria-haspopup="listbox"
          aria-expanded="false"
          disabled={@disabled}
          phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        >
          <span class="flex-1 truncate text-left">
            <%= cond do %>
              <% @chosen -> %>
                {render_slot(@chosen)}
              <% @search && @value != "" -> %>
                {@value}
              <% true -> %>
                {@prompt}
            <% end %>
          </span>
          <.icon name="hero-chevron-down-mini" class="w-4 h-4 shrink-0" />
        </button>
        <div
          class="fcon-popover"
          data-fcon-pop-panel
          role="listbox"
          hidden
          phx-mounted={JS.ignore_attributes(["hidden", "style"])}
        >
          <input
            :if={@searchable}
            type="search"
            class="fcon-combobox-search fcon-input--compact"
            placeholder="Filter"
            aria-label="Filter the choices"
            data-fcon-filter
          />
          <input
            :if={@search}
            type="search"
            class="fcon-combobox-search fcon-input--compact"
            placeholder="Search"
            aria-label="Search the choices"
            value={@query}
            phx-keyup={@search}
            phx-debounce="300"
            data-testid={@testid && "#{@testid}-search"}
          />
          <button
            :for={option <- @option}
            type="button"
            role="option"
            aria-checked={to_string(option.value == @value)}
            data-testid={@testid && "#{@testid}-#{option.value}"}
            data-fcon-pop-item
            phx-click={
              JS.set_attribute({"value", option.value}, to: "##{@id}-value")
              |> JS.dispatch("change", to: "##{@id}-value", bubbles: true)
            }
            class="fcon-option"
          >
            <.icon name="hero-check-mini" class="fcon-option-check w-4 h-4" />
            <span class="truncate">{render_slot(option)}</span>
          </button>
          <p :if={@more > 0} class="fcon-figures px-2 py-1" data-testid={@testid && "#{@testid}-more"}>
            {Format.count(@more)} more match · keep typing
          </p>
        </div>
      </div>
      <p :if={@hint} class="fcon-hint">{code_names(@hint)}</p>
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
  attr :search, :string, default: nil, doc: "as `combobox/1` takes it, for a set too long to hold"
  attr :query, :string, default: ""
  attr :matches, :integer, default: nil

  def enumerated_field(%{error: nil} = assigns) do
    ~H"""
    <.combobox
      id={@testid}
      name={@name}
      label={@label}
      value={@value}
      prompt={((@options == [] and @query == "") && @empty) || @prompt}
      hint={@hint}
      disabled={@options == [] and is_nil(@search)}
      search={@search}
      query={@query}
      matches={@matches}
      testid={@testid}
    >
      <:option :if={@prompt} value="">{@prompt}</:option>
      <:option :for={{label, value} <- @options} value={to_string(value)}>{label}</:option>
    </.combobox>
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
    <span class={["fcon-chip", @mono && "fcon-chip--mono"]} data-testid={@testid} title={@title}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A controller value as a badge: its words from `FlezhaConsoleWeb.Words`, painted
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
    <.badge
      said={@said}
      count={@count}
      class={@class}
      title={@title}
      data-testid={@testid || (@kind == :health && "health-badge")}
      data-health={@kind == :health && to_string(@value || :unknown)}
      data-state={@kind != :health && state_attr(@value)}
    />
    """
  end

  attr :said, :map, required: true, doc: "`%{text:, tone:}`, and a `shape:` to draw"
  attr :count, :any, default: nil
  attr :class, :any, default: nil
  attr :title, :string, default: nil
  attr :rest, :global

  defp badge(assigns) do
    ~H"""
    <span {@rest} class={["fcon-badge", tone_class(@said.tone), @class]} title={@title}>
      <span :if={@said[:shape]} class="fcon-shape" data-shape={@said.shape} aria-hidden="true"></span>
      <span :if={not is_nil(@count)} class="fcon-badge-count">{@count}</span>
      {@said.text}
    </span>
    """
  end

  # A value the browser tests can read back; a compound one is named by its words.
  defp state_attr(value) when is_atom(value) or is_binary(value), do: to_string(value)
  defp state_attr(_compound), do: nil

  defp tone_class(:positive), do: "fcon-badge--positive"
  defp tone_class(:warning), do: "fcon-badge--warning"
  defp tone_class(:negative), do: "fcon-badge--negative"
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
    <span class={"fcon-tone-#{@said.tone}"} data-testid={@testid} phx-no-format>{if @lower, do: String.downcase(@said.text), else: @said.text}</span>
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
    <span class="fcon-strip" data-testid={@testid} aria-hidden="true">
      <span
        :for={{health, count} <- @counts}
        :if={count > 0}
        class="fcon-strip-part"
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

  attr :paging, :map,
    default: nil,
    doc: "the screen's `@paging`: the grid shows a page of rows and grows on request"

  attr :page_size, :integer, default: 20

  attr :total, :integer,
    default: nil,
    doc: "the collection's size, when `rows` is the page the controller answered for `@paging`"

  attr :older, :string,
    default: nil,
    doc: "what growing reads once every held row is shown, while the source holds older ones"

  attr :expand, :any,
    default: nil,
    doc:
      "fn row -> nil, or `{id, rows}` drawn under it as a paged listing of its own, " <>
        "kept under `id`; a page counts only the rows it expands"

  attr :menu_help, :list,
    default: [],
    doc: "glossary keys explaining the row menu's actions, as a \"?\" over it"

  slot :col, required: true do
    attr :label, :string
    attr :num, :boolean
    attr :class, :string
    attr :help, :list, doc: "glossary keys explaining the column, as a \"?\" beside its label"
  end

  slot :menu, doc: "the row's menu, in the last column"
  slot :foot

  def grid(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    # A stream is never sliced: its rows are not held here to count. The page
    # is its own assign, since a page holding every row equals `rows` and
    # would not count as changed when the listing grows to it. A controller
    # listing's rows are already its page, and `total` counts the rest.
    assigns =
      case assigns do
        %{paging: %{} = paging, rows: rows} when is_list(rows) ->
          listing = listing_page(assigns)

          assigns
          |> assign(listing)
          |> assign(:page, open_rows(listing.page, assigns.expand, paging))

        _unpaged ->
          assign(assigns,
            page: open_rows(assigns.rows, assigns.expand, assigns.paging),
            shown: nil,
            total: nil,
            reach: nil
          )
      end

    ~H"""
    <div class="fcon-grid-wrap">
      <%!-- The roles are explicit because a phone lays the rows out as cards,
            and a table part whose display changes can lose its role. --%>
      <table class="fcon-grid" role="table" data-testid={@testid}>
        <thead
          role="rowgroup"
          data-explained={(@menu_help != [] or Enum.any?(@col, & &1[:help])) && "true"}
        >
          <tr role="row">
            <th
              :for={{col, index} <- Enum.with_index(@col)}
              role="columnheader"
              class={col[:num] && "fcon-cell-num"}
            >
              {col[:label]}
              <.help_tip
                :if={col[:help]}
                id={"#{@id}-help-#{index}"}
                label={"What #{col[:label]} means"}
                align={(col[:num] && "end") || "start"}
                terms={col.help}
              />
            </th>
            <th :if={@menu != []} role="columnheader" class="fcon-cell-menu">
              <span class="sr-only">Actions</span>
              <.help_tip
                :if={@menu_help != []}
                id={"#{@id}-help-menu"}
                label="What the row actions do"
                align="end"
                terms={@menu_help}
              />
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          role="rowgroup"
          phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
        >
          <%= for row <- @page do %>
            <%!-- An opened row's own listing, grown by its own control. --%>
            <tr
              :if={match?(%{more_of: _}, row)}
              role="row"
              class="fcon-grid-more"
              id={"#{row.more_of}-foot"}
            >
              <td role="cell" colspan={length(@col) + if(@menu != [], do: 1, else: 0)}>
                <.more id={row.more_of} shown={row.shown} total={row.total} step={@page_size} />
              </td>
            </tr>
            <tr
              :if={!match?(%{more_of: _}, row)}
              role="row"
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
              <td
                :for={col <- @col}
                role="cell"
                data-label={col[:label]}
                class={[col[:num] && "fcon-cell-num", col[:class]]}
              >
                {render_slot(col, @row_item.(row))}
              </td>
              <td :if={@menu != []} role="cell" class="fcon-cell-menu" phx-click={own_click()}>
                {render_slot(@menu, @row_item.(row))}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
      <div :if={@foot != [] or (@shown && (@total > @shown or @older))} class="fcon-grid-foot">
        {render_slot(@foot)}
        <.more
          :if={@shown}
          id={@id}
          shown={@shown}
          total={@total}
          step={@page_size}
          older={@older}
          reach={@reach}
        />
      </div>
    </div>
    """
  end

  # The rows with what each opened row draws under it: the first page of its
  # own listing, and the control that grows it.
  defp open_rows(rows, nil, _paging), do: rows

  defp open_rows(rows, expand, paging) when is_list(rows) do
    Enum.flat_map(rows, fn row ->
      case expand.(row) do
        {id, [_ | _] = opened} ->
          shown = Sections.shown(paging, id)
          more = %{more_of: id, shown: shown, total: length(opened)}
          [row | Enum.take(opened, shown)] ++ if(length(opened) > shown, do: [more], else: [])

        _closed ->
          [row]
      end
    end)
  end

  @doc """
  A listing that is not a grid, paged the way a grid is: its inner block is
  given the rows to show, and the control that grows it follows.

      <.paged :let={page} id="sinks" rows={@sinks} paging={@paging}>
        <ul><li :for={sink <- page}>…</li></ul>
      </.paged>
  """
  attr :id, :string, required: true, doc: "the listing's id, the key its count is kept under"
  attr :rows, :list, required: true
  attr :paging, :map, required: true, doc: "the screen's `@paging`"
  attr :page_size, :integer, default: 20
  attr :older, :string, default: nil, doc: "as `grid/1` takes it"
  attr :total, :integer, default: nil, doc: "as `grid/1` takes it"
  slot :inner_block, required: true

  def paged(assigns) do
    assigns = assign(assigns, listing_page(assigns))

    ~H"""
    {render_slot(@inner_block, @page)}
    <.more id={@id} shown={@shown} total={@total} step={@page_size} older={@older} reach={@reach} />
    """
  end

  # The page a listing shows of its `rows`: the first `shown` of them, or for
  # a controller listing (`total` given) the rows already read, at most the
  # controller's reach.
  defp listing_page(%{rows: rows, total: total, paging: paging, id: id, page_size: size})
       when is_integer(total) do
    %{
      page: rows,
      shown: min(length(rows), Sections.limit(paging, id, size)),
      total: total,
      reach: Sections.reach()
    }
  end

  defp listing_page(%{rows: rows, paging: paging, id: id, page_size: size}) do
    shown = Sections.shown(paging, id, size)
    %{page: Enum.take(rows, shown), shown: shown, total: length(rows), reach: nil}
  end

  @doc """
  The search box of a listing searched through `Live.Sections`: its text is
  kept per listing in the screen's `@searches`, and each change starts the
  listing again at its first page.
  """
  attr :listing, :string, required: true, doc: "the listing's id"
  attr :searches, :map, required: true, doc: "the screen's `@searches`"
  attr :testid, :string, required: true, doc: "the box's; its form's adds `-form`"
  attr :label, :string, default: nil
  attr :placeholder, :string, default: "Search"
  attr :class, :string, default: nil

  def listing_search(assigns) do
    ~H"""
    <form
      phx-change="listing_search"
      onsubmit="return false"
      class={@class}
      data-testid={"#{@testid}-form"}
    >
      <input type="hidden" name="listing" value={@listing} />
      <.input
        type="search"
        name="q"
        id={@testid}
        label={@label}
        value={Sections.search(@searches, @listing)}
        placeholder={@placeholder}
        aria-label={@label || @placeholder}
        phx-debounce="300"
        compact
        data-testid={@testid}
      />
    </form>
    """
  end

  @doc """
  The control that grows a listing by a page, stating how many of how many it
  shows; nothing once every row is shown. `grid/1` and `paged/1` render it.

  A listing whose source pages by cursor holds only the rows read so far, so
  its total is not known: once every held row is shown, `older` names what
  growing reads next, and the screen reads it in `listing_grown/2` (see
  `FlezhaConsoleWeb.Live.Sections`).
  """
  attr :id, :string, required: true, doc: "the listing's id, the key its count is kept under"
  attr :shown, :integer, required: true
  attr :total, :integer, required: true
  attr :step, :integer, default: 20
  attr :older, :string, default: nil

  attr :reach, :integer,
    default: nil,
    doc: "the most rows a controller listing reads; past it the foot asks to narrow instead"

  def more(%{reach: reach, shown: shown, total: total} = assigns)
      when is_integer(reach) and shown >= reach and total > shown do
    ~H"""
    <p class="fcon-figures" data-testid={"#{@id}-reach"}>
      Showing {Format.count(@shown)} of {Format.count(@total)} · search or filter to narrow
    </p>
    """
  end

  def more(assigns) do
    ~H"""
    <button
      :if={@total > @shown or @older}
      type="button"
      class="fcon-more"
      phx-click="grid_more"
      phx-value-id={@id}
      phx-value-shown={@shown}
      phx-value-step={@step}
      data-testid={"#{@id}-more"}
    >
      <%= if @total > @shown do %>
        Show {min(@step, @total - @shown)} more · {Format.count(@shown)} of {Format.count(@total)}
      <% else %>
        {@older} · {@total} shown
      <% end %>
    </button>
    """
  end

  @doc """
  The `phx-click` of an element inside an activatable grid row that handles
  its own click — a link, a menu — so the row does not activate as well. The
  event it dispatches has no listener: claiming the click is the whole point.
  """
  def own_click, do: JS.dispatch("fcon:own-click")

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
          data-fcon-pop-item
          class={["fcon-menu-item", item[:danger] && "fcon-menu-item--danger"]}
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
          data-fcon-pop-item
          class={["fcon-menu-item", item[:danger] && "fcon-menu-item--danger"]}
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
  One labelled figure in a `<dl class="fcon-facts">` of them — the shape every
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
    <div class="fcon-fact">
      <dt>{@label}</dt>
      <dd
        data-testid={@testid}
        class={[@tone && "fcon-tone-#{@tone}", @mono && "fcon-ident"]}
      >
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  @doc """
  A time in a table cell: how long ago or until, over the absolute time in
  muted ink, with the full timestamp as its title. `at` is a `DateTime` or
  unix time in `unit`; `now`, in the same unit, defaults to the clock. A missing time reads
  "—".
  """
  attr :at, :any, required: true
  attr :unit, :atom, default: :second, values: [:second, :millisecond]
  attr :now, :integer, default: nil
  attr :tone, :atom, default: nil, values: [nil, :positive, :warning, :negative, :neutral]
  attr :testid, :string, default: nil

  def moment(%{at: %DateTime{} = at} = assigns),
    do: moment(%{assigns | at: DateTime.to_unix(at, assigns.unit)})

  def moment(%{at: at} = assigns) when not is_integer(at) do
    ~H"""
    <span data-testid={@testid}>—</span>
    """
  end

  def moment(assigns) do
    assigns =
      assign(assigns,
        relative: Format.relative(assigns.at, assigns.unit, assigns.now),
        absolute: Format.unix_time(assigns.at, assigns.unit)
      )

    ~H"""
    <span data-testid={@testid} title={@absolute} class="fcon-moment">
      <span class={@tone && "fcon-tone-#{@tone}"}>{@relative}</span>
      <span class="fcon-muted block text-xs">{@absolute}</span>
    </span>
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
  attr :title, :string, default: nil
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
      title={@title}
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
  attr :area, :boolean, default: false, doc: "also fill the area under the line"

  def sparkline(assigns) do
    values = Enum.map(assigns.samples, &sample_value(&1, assigns.key))

    assigns =
      assigns
      |> assign(:values, values)
      |> assign(:points, spark_points(values, assigns.width, assigns.height))

    ~H"""
    <svg
      :if={length(@values) >= 2}
      class="fcon-spark"
      viewBox={"0 0 #{@width} #{@height}"}
      width={@width}
      height={@height}
      preserveAspectRatio="none"
      role="img"
      aria-label={"#{@label}: #{length(@values)} samples, peak #{Enum.max(@values)} msgs/s"}
      data-testid={@testid}
      data-samples={length(@values)}
    >
      <polygon
        :if={@area}
        class="fcon-spark-area"
        points={"0,#{@height} #{@points} #{@width},#{@height}"}
      />
      <polyline points={@points} />
    </svg>
    """
  end

  defp sample_value(sample, _key) when is_number(sample), do: sample
  defp sample_value(sample, key) when is_map(sample), do: Map.get(sample, key) || 0
  defp sample_value(_sample, _key), do: 0

  @doc """
  The polyline points for `values` in a `width` × `height` box, oldest first,
  scaled to the peak.
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
      class="fcon-meter"
      role="meter"
      aria-label={@label}
      aria-valuenow={@value || 0}
      aria-valuemin="0"
      aria-valuemax={@max}
      data-tone={@tone}
      data-testid={@testid}
    >
      <span class="fcon-meter-fill" style={"width: #{@percent}%"}></span>
    </span>
    """
  end

  @doc """
  An indicator: one figure under its icon and label, with a verdict pill
  beside it and a sentence saying what it means. The tone tints the icon and
  the pill, and is drawn as a shape too. A changed figure is marked as it
  changes. `href` makes the whole tile a link; the inner block holds a strip,
  a meter, a sparkline or links of its own, so a tile holding links takes no
  `href`.

      <.tile testid="ns-relays" icon="hero-cpu-chip" label="Relays" value={8}
             tone={:warning} verdict="1 suspended" condition="7 healthy, 1 suspended">
        <.strip counts={@health} />
      </.tile>
  """
  attr :testid, :string, required: true, doc: "also names the figure's DOM id"
  attr :label, :string, required: true

  attr :term, :string,
    default: nil,
    doc: "a glossary key the label explains in place; not on a tile with `href`"

  attr :icon, :string, default: nil, doc: "a `hero-*` name, drawn as a glyph in the tone"

  attr :verdict, :string,
    default: nil,
    doc: "the tone in a word or two, as a pill beside the figure"

  attr :live, :boolean,
    default: false,
    doc: "re-read every few seconds: figures in mono and a pulse in the corner"

  attr :value, :any,
    default: nil,
    doc: "the figure; nil draws none. A number of 10 000 or more is compact"

  attr :unit, :string, default: nil, doc: "the figure's unit, set small beside it"
  attr :tone, :atom, default: :neutral, values: [:positive, :warning, :negative, :neutral]
  attr :condition, :string, default: nil, doc: "what the figure means, in words"
  attr :href, :string, default: nil
  slot :inner_block
  slot :foot, doc: "a link or what the tile leaves out, on its bottom line"
  slot :edge, doc: "a chart drawn edge to edge across the tile, just above its foot"

  def tile(%{href: href} = assigns) when is_binary(href) do
    ~H"""
    <.link
      navigate={@href}
      class={tile_class(@live)}
      data-testid={@testid}
      data-tone={@tone}
    >
      <.tile_body {assigns} />
    </.link>
    """
  end

  def tile(assigns) do
    ~H"""
    <div class={tile_class(@live)} data-testid={@testid} data-tone={@tone}>
      <.tile_body {assigns} />
    </div>
    """
  end

  defp tile_class(live),
    do: ["fcon-tile fcon-indicator flz-tile", live && "fcon-indicator--live"]

  # Four rows, always — head, figure, body, end — so every tile of a row puts
  # its parts on the same lines.
  defp tile_body(assigns) do
    assigns = assign(assigns, :shown, assigns.value && Format.compact(assigns.value))

    ~H"""
    <span class="fcon-indicator-head">
      <.glyph :if={@icon} icon={@icon} tone={@tone} />
      <span class="fcon-indicator-label">
        <%= if @term && !@href do %>
          <.term key={@term} id={"#{@testid}-term"}>{@label}</.term>
        <% else %>
          {@label}
        <% end %>
      </span>
    </span>
    <span :if={@live} class="fcon-indicator-pulse" aria-hidden="true"></span>
    <span class="fcon-indicator-figure flz-figure-fit">
      <span
        :if={is_nil(@verdict) and @tone != :neutral}
        class={"fcon-shape fcon-tone-#{@tone}"}
        data-shape={Words.shape(@tone)}
        aria-hidden="true"
      >
      </span>
      <.live_value
        :if={not is_nil(@value)}
        id={"#{@testid}-value"}
        value={@shown}
        title={"#{@value}#{@unit && " " <> @unit}"}
        class="fcon-figure flz-figure-value"
        testid={"#{@testid}-value"}
      />
      <span :if={@unit && not is_nil(@value)} class="flz-figure-unit">{@unit}</span>
      <.badge
        :if={@verdict}
        said={%{text: @verdict, tone: @tone, shape: Words.shape(@tone)}}
        data-testid={"#{@testid}-verdict"}
      />
    </span>
    <span class="fcon-indicator-body">
      <span :if={@condition} class="fcon-figures" data-testid={"#{@testid}-condition"}>
        {@condition}
      </span>
      {render_slot(@inner_block)}
    </span>
    <span class="fcon-indicator-end">
      {render_slot(@edge)}
      <span :if={@foot != [] or @href} class="fcon-indicator-foot flz-tile-foot">
        <span class="fcon-indicator-foot-text">{render_slot(@foot)}</span>
        <.icon :if={@href} name="hero-arrow-right" class="fcon-indicator-go" />
      </span>
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
    <pre id={@id} data-testid={@testid} class={["fcon-code", @class]}>{render_slot(@inner_block)}</pre>
    """
  end

  @doc """
  A command line that does what a flow will, ready to copy: a `flz` command a
  review shows beside what it states. A note may follow it.
  """
  attr :id, :string, required: true
  attr :testid, :string, required: true
  attr :command, :string, required: true
  slot :inner_block

  def command(assigns) do
    ~H"""
    <div class="fcon-command">
      <div class="fcon-command-head">
        <p class="fcon-eyebrow">The same from the CLI</p>
        <.button
          variant="secondary"
          size="sm"
          icon="hero-clipboard"
          data-fcon-copy-from={"##{@id}"}
          data-testid={"#{@testid}-copy"}
        >
          Copy
        </.button>
      </div>
      <.code_block id={@id} testid={@testid}>{@command}</.code_block>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  An icon on a tile, tinted with one of the wire hues, which tells a kind of
  thing apart from its neighbours — a provider's role, a factory's run — or
  with a status tone, which says how that thing is. What it is, is said in
  words beside it.
  """
  attr :icon, :string, required: true

  attr :tone, :any,
    required: true,
    doc: "a wire hue, 0 to 5, or `:positive`, `:warning`, `:negative` or `:neutral`"

  attr :size, :string, default: "md", values: ~w(md lg)

  def glyph(assigns) do
    ~H"""
    <span class={["fcon-glyph", @size == "lg" && "fcon-glyph--lg"]} data-tone={@tone}>
      <.icon name={@icon} class={if @size == "lg", do: "h-6 w-6", else: "h-5 w-5"} />
    </span>
    """
  end

  @doc "A key, as the keyboard labels it."
  slot :inner_block, required: true

  def kbd(assigns) do
    ~H"""
    <kbd class="fcon-kbd">{render_slot(@inner_block)}</kbd>
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
      class={["fcon-ident", @class]}
      title={@text}
      aria-label={@text}
      data-fcon-copy={@text}
      data-testid={@testid}
    >
      {@shown}
    </button>
    <span :if={!@copy} class={["fcon-ident", @class]} data-testid={@testid}>{@shown}</span>
    """
  end

  @doc """
  A flezha term where a screen first uses it: dotted, with its glossary
  definition shown on hover and on keyboard focus, as its accessible
  description. Activating it pins the same definition beside it, through the
  console's popover behaviour, and marks the term expanded until it closes.

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
    <span class="fcon-tip-host" data-fcon-pop phx-no-format><button
        type="button"
        class="fcon-term"
        aria-describedby={@tip_id}
        aria-haspopup="dialog"
        aria-expanded="false"
        data-fcon-pop-trigger
        data-testid={"term-#{@entry.key}"}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >{if @inner_block != [], do: render_slot(@inner_block), else: @entry.key}</button><span
        role="tooltip"
        id={@tip_id}
        class="fcon-tooltip"
      ><span class="fcon-tooltip-term">{@entry.name}</span>{@entry.definition}</span><span
        class="fcon-popover fcon-popover--start fcon-help-panel"
        role="dialog"
        aria-label={@entry.name}
        data-fcon-pop-panel
        data-testid={"term-panel-#{@entry.key}"}
        hidden
        phx-mounted={JS.ignore_attributes(["hidden", "style"])}
      ><span class="fcon-tooltip-term">{@entry.name}</span>{@entry.definition}</span></span>
    """
  end

  # Every condition's rows, in the one order each surface shows them.
  @condition_rows [
    state: "State",
    cause: "Cause",
    impact: "Impact",
    runner: "Runner",
    handled: "Handled by",
    next: "Next step"
  ]

  @doc """
  A condition as labelled rows in one fixed order: State, Cause, Impact,
  Runner, Handled by, Next step. `facts` holds a value per row key; a row
  whose value is nil or absent is left out. A value is a phrase, or a said
  map (`%{text:, tone:}` with an optional `:shape` and glossary `:term`)
  drawn with its shape. A `:row` slot adds a row whose value is markup, after
  the others.
  """
  attr :facts, :map, required: true
  attr :testid, :string, required: true
  attr :state, :atom, default: nil, doc: "the condition's state, as `data-state`"

  slot :row do
    attr :key, :string, required: true
    attr :label, :string, required: true
  end

  def condition(assigns) do
    rows =
      for {key, label} <- @condition_rows,
          value = assigns.facts[key],
          do: %{key: key, label: label, value: value}

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <dl class="fcon-state-summary" data-testid={@testid} data-state={@state}>
      <div :for={row <- @rows} data-testid={"#{@testid}-#{row.key}"}>
        <dt>{row.label}</dt>
        <dd :if={is_map(row.value)} class="fcon-condition-said">
          <span
            class={"fcon-shape fcon-tone-#{row.value.tone}"}
            data-shape={row.value[:shape] || Words.shape(row.value.tone)}
            aria-hidden="true"
          >
          </span>
          <.term :if={row.value[:term]} key={row.value.term} id={"#{@testid}-#{row.key}-term"}>
            {row.value.text}
          </.term>
          <span :if={!row.value[:term]}>{row.value.text}</span>
        </dd>
        <dd :if={!is_map(row.value)}>{row.value}</dd>
      </div>
      <div :for={row <- @row} data-testid={"#{@testid}-#{row.key}"}>
        <dt>{row.label}</dt>
        <dd>{render_slot(row)}</dd>
      </div>
    </dl>
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
    <span class="fcon-tip-host" phx-no-format>{render_slot(@inner_block)}<span role="tooltip" id={@id} class="fcon-tooltip">{@text}</span></span>
    """
  end

  @doc """
  A "?" beside a heading or a control that explains it in plain words when
  clicked, and stays open while it is read. `terms` explains glossary terms,
  each by its name and definition, after anything the block says.

      <.help_tip id="help-quotas" label="What quotas are">
        A quota caps how many relays the namespace may run.
      </.help_tip>
      <.help_tip id="help-lag" terms={["fsync lag"]} />
  """
  attr :id, :string, required: true
  attr :label, :string, default: "What is this?"
  attr :align, :string, default: "start", values: ~w(start end)
  attr :terms, :list, default: [], doc: "glossary keys whose definitions it explains"
  slot :inner_block

  def help_tip(assigns) do
    assigns = assign(assigns, :entries, Enum.map(assigns.terms, &Glossary.term!/1))

    ~H"""
    <.popover
      id={@id}
      testid={@id}
      label={@label}
      role="dialog"
      align={@align}
      trigger_class="fcon-help-tip"
      panel_class="fcon-help-panel"
    >
      <:trigger><.icon name="hero-question-mark-circle" class="w-5 h-5" /></:trigger>
      {render_slot(@inner_block)}
      <dl :if={@entries != []} class="space-y-2">
        <div :for={entry <- @entries}>
          <dt class="fcon-tooltip-term">{entry.name}</dt>
          <dd>{entry.definition}</dd>
        </div>
      </dl>
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
      class={["fcon-note", @kind == :error && "fcon-note--error", @class]}
    >
      <.icon name={@resolved_icon} class="fcon-note-icon w-5 h-5" />
      <div class="min-w-0 space-y-2">{render_slot(@inner_block)}</div>
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
    <div data-testid={@testid} class="fcon-empty">
      <.icon name={@icon} class="fcon-empty-icon w-6 h-6" />
      <p class="fcon-empty-text">{render_slot(@inner_block)}</p>
      <p :if={@detail != []} class="fcon-empty-text">{render_slot(@detail)}</p>
      <div :if={@action != []} class="fcon-empty-actions">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc """
  That a screen's cluster reads are partial: how many of the cluster's
  controllers answered, and which did not. Nothing when every one answered.

  `unreachable` is `NodeManager.unreachable/1` of the screen's reads, and
  `controllers` the controllers listing the shell's pulse holds, `nil` before
  it is read. A screen renders it once, above the region its reads fill.
  """
  attr :unreachable, :list, required: true
  attr :controllers, :list, default: nil

  def partial_answer(assigns) do
    ~H"""
    <.notice :if={@unreachable != []} icon="hero-signal-slash" testid="partial-answer">
      <p>{partial_words(@unreachable, @controllers)}</p>
    </.notice>
    """
  end

  defp partial_words(unreachable, controllers) do
    missing = unreachable |> Enum.map(&to_string/1) |> Words.join()
    {holds, they} = if length(unreachable) == 1, do: {"holds", "it"}, else: {"hold", "they"}
    rest = "so what #{they} #{holds} is missing here."

    case controllers do
      [_ | _] ->
        total = controllers |> Enum.map(& &1.node) |> Enum.concat(unreachable) |> Enum.uniq()

        "#{answered_words(length(total) - length(unreachable), length(total))}; " <>
          "#{missing} did not, #{rest}"

      _unread ->
        "#{missing} did not answer, #{rest}"
    end
  end

  @doc ~S|"2 of 3 controllers answered"|
  def answered_words(answered, total),
    do: "#{answered} of #{Words.count(total, "controller")} answered"

  @doc """
  What a listing says in place of its empty state when its read is partial:
  nothing was found on the controllers that answered, which says nothing of
  the ones that did not.
  """
  attr :noun, :string, required: true, doc: "what the listing holds, singular"
  attr :testid, :string, default: "partial-empty"

  def partial_empty(assigns) do
    ~H"""
    <.empty_state icon="hero-signal-slash" testid={@testid}>
      No {@noun} was found on the controllers that answered.
    </.empty_state>
    """
  end

  @doc """
  The controller a row lives on, by the machine it runs on, with its node name
  on hover. `controllers` is the controllers listing that names machines; a
  node it does not list is named by its host.
  """
  attr :node, :any, required: true
  attr :controllers, :list, default: nil
  attr :testid, :string, default: "row-controller"

  def controller_name(assigns) do
    row = Enum.find(assigns.controllers || [], &(&1.node == assigns.node))
    assigns = assign(assigns, :machine, machine(row || %{node: assigns.node}))

    ~H"""
    <span :if={@node} class="fcon-num" title={to_string(@node)} data-testid={@testid}>
      {@machine}
    </span>
    """
  end

  @doc """
  A listing's filter by the controller its rows live on, inside the listing's
  own filter form. Only offered when `rows` come from more than one
  controller; `NodeManager.rows_with(rows, :node, value)` applies it.
  """
  attr :rows, :list, required: true
  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :controllers, :list, default: nil
  attr :class, :string, default: "w-44"

  def controller_filter(assigns) do
    assigns = assign(assigns, :nodes, NodeManager.row_controllers(assigns.rows))

    ~H"""
    <.combobox
      :if={length(@nodes) > 1 or @value not in [nil, ""]}
      label="Controller"
      id="filter-controller"
      name={@name}
      value={@value}
      testid="filter-controller"
      prompt="All"
      class={@class}
    >
      <:option value="">All</:option>
      <:option :for={node <- @nodes} value={to_string(node)}>
        {machine(Enum.find(@controllers || [], &(&1.node == node)) || %{node: node})}
      </:option>
    </.combobox>
    """
  end

  @doc "The machine a controllers-listing row runs on, or its host when it does not say."
  def machine(%{host_node: "" <> machine}), do: machine
  def machine(%{host: "" <> host}), do: host
  def machine(%{node: node}), do: node |> to_string() |> String.split("@") |> List.last()

  @doc """
  What a screen shows in the shape of what it will show, before its first
  read lands — never an empty table or an empty state the data has not
  confirmed.
  """
  attr :rows, :integer, default: 4
  attr :testid, :string, default: "skeleton"

  def skeleton(assigns) do
    ~H"""
    <div class="fcon-skeleton-rows" data-testid={@testid} aria-busy="true" aria-label="Loading">
      <span
        :for={index <- 1..@rows}
        class="fcon-skeleton"
        style={"width: #{100 - rem(index * 17, 40)}%"}
      >
      </span>
    </div>
    """
  end

  @doc """
  Renders a banner for a normalised `FlezhaConsole.Service.NodeManager` error.

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
    error = assigns.error && NodeManager.error(assigns.error)
    {text, reason} = if error, do: split_reason(error, assigns.action), else: {nil, nil}

    assigns =
      assign(assigns,
        error: error,
        text: text,
        reason: reason,
        settings_link?: settings_link?(assigns.error)
      )

    ~H"""
    <.notice :if={@error} kind={@kind} testid="runtime-error" class={@class}>
      <p class="fcon-note-title">{code_names(@text)}</p>
      <.code_block :if={@reason} testid="runtime-error-reason">{@reason}</.code_block>
      <div :if={@error.hint}>
        <p class="fcon-eyebrow mb-1">Next step</p>
        <.code_block testid="runtime-error-hint">{@error.hint}</.code_block>
      </div>
      <p :if={not String.starts_with?(@error.code, "console.")} class="fcon-note-meta">
        <a
          href={reference_url(@error.code)}
          target="_blank"
          rel="noopener noreferrer"
          title={"What #{@error.code} means"}
          data-testid="runtime-error-reference"
        >
          Reference <code data-testid="runtime-error-code">{@error.code}</code>
        </a>
      </p>
      <.link :if={@settings_link?} href={~p"/users/settings"}>
        Store a flezha token in settings.
      </.link>
    </.notice>
    """
  end

  # A reason the controller could only inspect (a raw Erlang term) ends the
  # message; it reads better set apart in mono than run into the sentence.
  defp split_reason(%{details: %{reason: "" <> reason}} = error, action)
       when binary_part(reason, 0, 1) in ["{", "[", "%", ":", "#"] do
    text = error_text(error, action)

    if String.ends_with?(text, ": " <> reason),
      do: {String.replace_suffix(text, ": " <> reason, "."), reason},
      else: {text, nil}
  end

  defp split_reason(error, action), do: {error_text(error, action), nil}

  # Core's errors reference has one section per family — the code before its
  # first dot — and no anchor per code, so the family is the deepest link.
  defp reference_url(code) do
    [family | _] = String.split(code, ".", parts: 2)
    "#{Application.fetch_env!(:flezha_console, :core_docs_url)}/errors.html##{family}"
  end

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
      {code_names(@error)}
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
  def error_message(%{code: "console." <> _, class: class} = error, action) when class != :denied,
    do: error_text(error, action)

  def error_message(%{code: code, message: _} = error, action),
    do: "#{error_text(error, action)} (#{code})"

  def error_message(error, action), do: error_message(NodeManager.error(error), action)

  defp error_text(%{class: :denied, message: message}, action),
    do: "The controller refused #{action || "this call"}: #{message}"

  defp error_text(%{message: message}, _action), do: message

  @doc """
  Shows each name a controller message wraps in single quotes, like
  `relay 'orders'`, as code without the quotes. A value that is not a string
  is returned unchanged.
  """
  def code_names("" <> text) do
    # Apostrophes sit inside words ("the caller's role"), so a name's quote
    # must not touch a word character on its outer side.
    parts =
      ~r/(?<!\w)'[^'\n]+'(?!\w)/u
      |> Regex.split(text, include_captures: true)
      |> Enum.with_index()
      |> Enum.map(fn
        {part, index} when rem(index, 2) == 0 -> escape(part)
        {quoted, _index} -> ["<code>", escape(String.slice(quoted, 1..-2//1)), "</code>"]
      end)

    {:safe, parts}
  end

  def code_names(other), do: other

  defp escape(text), do: Phoenix.HTML.Engine.html_escape(text)

  @doc """
  Scrolls the element with `id` into view and marks it briefly, for a result
  that renders away from the control that asked for it. The `fcon:reveal`
  listener in app.js does the scrolling.
  """
  def reveal(socket, id), do: Phoenix.LiveView.push_event(socket, "fcon:reveal", %{id: id})

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
      <code>flz auth bootstrap &lt; storage/app/auth/bootstrap.token</code>
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
          code_names(error_message(@status.reason))}
      </span>
      <span :if={!@status.token?}>No flezha token is bound to this console.</span>
      Reads of the audit log and observability, and every mutation, will be refused.
      <.link href={~p"/users/settings"}>Store a token in settings.</.link>
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
  attr :trigger_class, :string, default: "fcon-iconbtn"
  attr :panel_class, :string, default: nil
  attr :role, :string, default: "menu"

  slot :trigger, required: true
  slot :inner_block, required: true

  def popover(assigns) do
    ~H"""
    <div id={@id} class="fcon-pop" data-fcon-pop>
      <button
        type="button"
        class={@trigger_class}
        data-fcon-pop-trigger
        data-testid={@testid}
        aria-label={@label}
        aria-haspopup={@role}
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        {render_slot(@trigger)}
      </button>
      <div
        class={["fcon-popover", "fcon-popover--#{@align}", @panel_class]}
        role={@role}
        data-fcon-pop-panel
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
  attr :subtitle, :string, default: nil, doc: "the subject's technical name, under the title"
  attr :on_close, :string, required: true
  attr :testid, :string, default: "inspector"
  slot :inner_block, required: true
  slot :actions

  def drawer(assigns) do
    ~H"""
    <div
      id={@id}
      class="fcon-drawer"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      data-testid={@testid}
      phx-hook="FlzFocus"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <div class="fcon-scrim" phx-click={@on_close}></div>
      <section class="fcon-drawer-panel">
        <header class="fcon-drawer-head">
          <div class="min-w-0 space-y-1">
            <p class="fcon-eyebrow">{@eyebrow}</p>
            <h2 id={"#{@id}-title"} class="fcon-drawer-title">{@title}</h2>
            <p :if={@subtitle} class="fcon-tech-name" data-testid={"#{@testid}-subtitle"}>
              {@subtitle}
            </p>
          </div>
          <button
            type="button"
            class="fcon-iconbtn"
            phx-click={@on_close}
            aria-label="Close"
            data-testid="inspector-close"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </header>
        <div class="fcon-drawer-body">
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
    values: ~w(confirm form wide flow),
    doc: "what the dialog is for; the width follows from it. `flow` holds a railed `steps/1`"

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
      class="fcon-dialog"
      phx-hook="FlzFocus"
      phx-window-keydown={@on_close}
      phx-key={@on_close && "Escape"}
    >
      <div class="fcon-scrim"></div>
      <div
        data-testid={@testid}
        role="dialog"
        aria-modal="true"
        aria-labelledby={@title != [] && "#{@id}-title"}
        class={["fcon-dialog-panel", "fcon-dialog-panel--#{@size}"]}
      >
        <div :if={@title != []} class="fcon-dialog-head">
          <h2 id={"#{@id}-title"} class="fcon-dialog-title">{render_slot(@title)}</h2>
          <button
            :if={@on_close}
            type="button"
            phx-click={@on_close}
            data-testid={@close_testid}
            class="fcon-iconbtn"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
        <div class="fcon-dialog-body">{render_slot(@inner_block)}</div>
        <div :if={@actions != []} class="fcon-dialog-foot">{render_slot(@actions)}</div>
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
    <div id={@id} class="fcon-toasts" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Lost the connection")}
        phx-disconnected={JS.show(to: ".phx-client-error #client-error", display: "flex")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {gettext("Trying to reconnect")}
        <.icon name="hero-arrow-path" class="fcon-spin ml-1 h-3 w-3" />
      </.flash>
      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong")}
        phx-disconnected={JS.show(to: ".phx-server-error #server-error", display: "flex")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Hang in there while we get back on track")}
        <.icon name="hero-arrow-path" class="fcon-spin ml-1 h-3 w-3" />
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
      class={["fcon-toast", @kind == :error && "fcon-toast--error"]}
      {@rest}
    >
      <.icon
        name={if @kind == :error, do: "hero-exclamation-circle", else: "hero-check-circle"}
        class="fcon-toast-icon w-5 h-5"
      />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="fcon-toast-title">{@title}</p>
        <p>{code_names(msg)}</p>
      </div>
      <button
        type="button"
        class="fcon-iconbtn"
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

  `rail` stands the steps down a rail beside the body instead, under a bar of
  how far the flow has come, each step with a summary of what was chosen
  there. With `on_step`, a done step is a control that sends that event with
  `phx-value-step`, so the operator can go back to it.
  """
  attr :steps, :list,
    required: true,
    doc: "each step's label, or `{label, summary}`, in order"

  attr :current, :integer, required: true, doc: "the current step's index"
  attr :testid, :string, default: "steps"
  attr :rail, :boolean, default: false
  attr :on_step, :string, default: nil
  slot :inner_block, doc: "the current step's body; a form may keep its fields below instead"
  slot :aside, doc: "a note at the foot of the rail"
  slot :foot

  def steps(assigns) do
    steps = Enum.map(assigns.steps, fn step -> if is_tuple(step), do: step, else: {step, nil} end)
    last = max(length(steps) - 1, 1)

    assigns =
      assign(assigns, steps: steps, progress: round(min(assigns.current, last) * 100 / last))

    ~H"""
    <div data-testid={@testid} data-step={@current} class={@rail && "fcon-flow"}>
      <div :if={@rail} class="fcon-flow-progress" aria-hidden="true">
        <span style={"width: #{@progress}%"}></span>
      </div>
      <div class={@rail && "fcon-flow-rail"}>
        <ol class="fcon-steps" aria-label="Steps">
          <li
            :for={{{label, summary}, index} <- Enum.with_index(@steps)}
            class="fcon-step"
            aria-current={index == @current && "step"}
            data-done={index < @current && "true"}
            data-testid={"#{@testid}-step-#{index}"}
          >
            <button
              :if={@on_step && index < @current}
              type="button"
              class="fcon-step-text"
              phx-click={@on_step}
              phx-value-step={index}
              data-testid={"#{@testid}-go-#{index}"}
            >
              <span class="fcon-step-label">{label}</span>
              <span :if={@rail && summary} class="fcon-step-summary">{summary}</span>
            </button>
            <span :if={!(@on_step && index < @current)} class="fcon-step-text">
              <span class="fcon-step-label">{label}</span>
              <span :if={@rail && summary} class="fcon-step-summary">{summary}</span>
            </span>
          </li>
        </ol>
        <div :if={@rail && @aside != []} class="fcon-flow-note">{render_slot(@aside)}</div>
      </div>
      <div :if={@inner_block != []} class="fcon-steps-body">{render_slot(@inner_block)}</div>
      <div :if={@foot != []} class="fcon-steps-foot">{render_slot(@foot)}</div>
    </div>
    """
  end

  @doc """
  Where a guided flow moves when the operator asks for `target` from
  `current`: back to any step already done, or forward one step, and only
  once `check` — the current step's own checks — answers `:ok`. Answers
  `{:ok, step}`, the check's `{:error, reason}`, or `:stay` for a target past
  `last` or more than one step ahead.
  """
  def move_step(current, target, _last, _check) when target <= current, do: {:ok, max(target, 0)}

  def move_step(current, target, last, check) when target == current + 1 and target <= last do
    with :ok <- check.(), do: {:ok, target}
  end

  def move_step(_current, _target, _last, _check), do: :stay

  @doc """
  Choosing one of a list, with the choice described beside it: a filter box
  and any further tools above, the list, and the description in a pane that
  stays in view. The filter narrows every item marked `data-fcon-item`, as
  `pick_choice/1` is, and a group of items it empties says nothing.
  """
  attr :search, :string, required: true, doc: "the filter box's placeholder and name"
  attr :search_testid, :string, required: true
  attr :list_testid, :string, required: true
  slot :tools
  slot :inner_block, required: true
  slot :detail, required: true

  def picker(assigns) do
    ~H"""
    <div class="fcon-pick" data-fcon-filterable>
      <div class="fcon-pick-tools">
        <input
          type="search"
          class="fcon-input--compact"
          placeholder={@search}
          aria-label={@search}
          data-fcon-filter
          data-testid={@search_testid}
        />
        {render_slot(@tools)}
      </div>
      <div class="fcon-pick-split">
        <div class="fcon-pick-list" data-testid={@list_testid}>{render_slot(@inner_block)}</div>
        {render_slot(@detail)}
      </div>
    </div>
    """
  end

  @doc """
  One item of a `picker/1`: a card with its glyph, its text, and a mark at the
  end that turns to a check once it is the chosen one. The click is the
  caller's.
  """
  attr :chosen, :boolean, required: true
  attr :glyph, :any, required: true, doc: "`{icon, tone}`, as `glyph/1` takes them"
  attr :rest, :global, include: ~w(disabled)
  slot :inner_block, required: true

  def pick_choice(assigns) do
    ~H"""
    <button
      type="button"
      class="fcon-choice fcon-choice--row"
      aria-pressed={to_string(@chosen)}
      data-fcon-item
      {@rest}
    >
      <.glyph icon={elem(@glyph, 0)} tone={elem(@glyph, 1)} />
      <span class="min-w-0">{render_slot(@inner_block)}</span>
      <.icon
        name={if @chosen, do: "hero-check-circle-mini", else: "hero-chevron-right-mini"}
        class="fcon-choice-mark h-5 w-5"
      />
    </button>
    """
  end

  @doc """
  The pane of a `picker/1` describing the chosen item: its glyph, title and
  subtitle, and what the caller says of it. With `empty`, an icon name,
  nothing is chosen yet and the inner block says what choosing will show.
  """
  attr :testid, :string, required: true
  attr :empty, :string, default: nil
  attr :glyph, :any, default: nil, doc: "`{icon, tone}`, as `glyph/1` takes them"
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :mono, :atom, default: nil, values: [nil, :title, :subtitle], doc: "which is an identifier"
  slot :inner_block, required: true

  def pick_pane(%{empty: icon} = assigns) when is_binary(icon) do
    ~H"""
    <aside class="fcon-pane fcon-pane--empty" data-testid={@testid}>
      <.icon name={@empty} class="h-8 w-8" />
      <p>{render_slot(@inner_block)}</p>
    </aside>
    """
  end

  def pick_pane(assigns) do
    ~H"""
    <aside class="fcon-pane" data-testid={@testid}>
      <div class="fcon-pane-head">
        <.glyph icon={elem(@glyph, 0)} tone={elem(@glyph, 1)} size="lg" />
        <div class="min-w-0">
          <h3 class={["fcon-pane-title", @mono == :title && "fcon-num"]}>{@title}</h3>
          <p :if={@subtitle} class={["fcon-muted text-xs", @mono == :subtitle && "fcon-num"]}>
            {@subtitle}
          </p>
        </div>
      </div>
      {render_slot(@inner_block)}
    </aside>
    """
  end

  # ======================================================================
  # Brand and icons
  # ======================================================================

  @doc "The product's name, as the lockup, page titles and brand links carry it."
  def product_name, do: "Flezha Console"

  @lockup_file Path.expand(
                 "../../../priv/static/images/flezha-console-badger-line-text-white.svg",
                 __DIR__
               )
  @external_resource @lockup_file

  # The lockup is not square, so its proportions are read from its own viewBox
  # rather than copied by hand.
  @lockup_aspect (case Regex.run(~r/viewBox="\S+ \S+ (\S+) (\S+)"/, File.read!(@lockup_file)) do
                    [_, width, height] -> "#{width} / #{height}"
                  end)

  @doc """
  The Flezha Console lockup, painted as a mask so it takes the ink of whatever it
  sits on: the chrome's ink in the rail, with the stylebook's own brand
  recipe, and the brand ink on the canvas.
  """
  attr :on, :atom, default: :canvas, values: [:chrome, :canvas]

  def brand_lockup(assigns) do
    assigns =
      assign(assigns, :mask, "url(#{~p"/images/flezha-console-badger-line-text-white.svg"})")

    ~H"""
    <span class={if @on == :chrome, do: "flz-brand", else: "fcon-brand fcon-brand--canvas"}>
      <span
        role="img"
        aria-label={product_name()}
        class={if @on == :chrome, do: "flz-logo", else: "fcon-logo"}
        style={"mask-image: #{@mask}; -webkit-mask-image: #{@mask}; aspect-ratio: #{lockup_aspect()}"}
      >
      </span>
    </span>
    """
  end

  defp lockup_aspect, do: @lockup_aspect

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

  def hide(js \\ %JS{}, selector), do: JS.hide(js, to: selector)

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(FlezhaConsoleWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(FlezhaConsoleWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
