defmodule FlezhaUiWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as modals, tables, and
  forms. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The default components use Tailwind CSS, a utility-first CSS framework.
  See the [Tailwind CSS documentation](https://tailwindcss.com) to learn
  how to customize them or feel free to swap in another framework altogether.

  Icons are provided by [heroicons](https://heroicons.com). See `icon/1` for usage.
  """
  use Phoenix.Component
  use Gettext, backend: FlezhaUiWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders a modal.

  ## Examples

      <.modal id="confirm-modal">
        This is a modal.
      </.modal>

  JS commands may be passed to the `:on_cancel` to configure
  the closing/cancel event, for example:

      <.modal id="confirm" on_cancel={JS.navigate(~p"/posts")}>
        This is another modal.
      </.modal>

  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div
        id={"#{@id}-bg"}
        class="bg-overlay fixed inset-0 transition-opacity backdrop-blur-sm"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center">
          <div class="w-full max-w-3xl p-4 sm:p-6 lg:py-8">
            <.focus_wrap
              id={"#{@id}-container"}
              phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
              class="relative hidden rounded-modal bg-modal-bg border border-modal-border p-14 shadow-modal transition animate-scale-in"
            >
              <div class="absolute top-6 right-5">
                <button
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  type="button"
                  class="-m-3 flex-none p-3 text-th-muted hover:text-th-secondary"
                  aria-label={gettext("close")}
                >
                  <.icon name="hero-x-mark-solid" class="h-5 w-5" />
                </button>
              </div>
              <div id={"#{@id}-content"}>
                {render_slot(@inner_block)}
              </div>
            </.focus_wrap>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The overlay and panel every dialog on the operator screens sits in.

  Padded and scrollable, so a panel taller than the viewport can still be
  reached — a provider declaring many fields makes one.

  ## Examples

      <.dialog :if={@open} testid="start-modal" size="max-w-md">
        ...
      </.dialog>
  """
  attr :testid, :string, default: nil
  attr :size, :string, default: "max-w-sm", doc: "max-width class for the panel"
  slot :inner_block, required: true

  def dialog(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-overlay backdrop-blur-sm p-6">
      <div
        data-testid={@testid}
        class={[
          "bg-modal-bg border border-modal-border rounded-modal w-full p-6",
          "shadow-modal animate-scale-in max-h-full overflow-y-auto",
          @size
        ]}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  A dialog asking the operator to confirm an action before it happens.

  Used for every irreversible verb on these screens, so they all ask the same
  way. `values` are sent with the confirm click, for a handler keyed on which
  row was acted on.

  ## Examples

      <.confirm_dialog
        :if={@confirm_stop}
        title="Stop operative?"
        confirm_label="Stop"
        on_confirm="stop_operative"
        on_cancel="cancel_stop"
        values={%{"operative_id" => @confirm_stop}}
        testid="stop-confirm-modal"
      >
        Stop <.mono>{@confirm_stop}</.mono>? This cannot be undone.
      </.confirm_dialog>
  """
  attr :title, :string, required: true
  attr :confirm_label, :string, required: true
  attr :on_confirm, :string, required: true
  attr :on_cancel, :string, required: true
  attr :values, :map, default: %{}
  attr :variant, :string, default: "danger", values: ~w(danger accent)
  attr :testid, :string, default: nil
  attr :cancel_testid, :string, default: nil
  attr :confirm_testid, :string, default: nil
  slot :inner_block, required: true

  def confirm_dialog(assigns) do
    ~H"""
    <.dialog testid={@testid}>
      <h3 class="text-lg font-semibold text-th-primary mb-3">{@title}</h3>
      <p class="text-sm text-th-tertiary mb-5">{render_slot(@inner_block)}</p>
      <div class="flex justify-end gap-3">
        <button
          phx-click={@on_cancel}
          data-testid={@cancel_testid}
          class="px-4 py-2 text-sm text-th-secondary hover:text-th-primary transition-colors"
        >
          Cancel
        </button>
        <button
          phx-click={@on_confirm}
          {values_attrs(@values)}
          data-testid={@confirm_testid}
          class={[
            "px-4 py-2 text-sm font-medium text-white rounded-xl transition-colors",
            @variant == "danger" && "bg-danger hover:bg-danger-hover",
            @variant == "accent" && "bg-accent hover:bg-accent-hover"
          ]}
        >
          {@confirm_label}
        </button>
      </div>
    </.dialog>
    """
  end

  defp values_attrs(values) do
    Map.new(values, fn {key, value} -> {"phx-value-#{key}", value} end)
  end

  @doc """
  An identifier rendered the way identifiers are rendered everywhere here.
  """
  slot :inner_block, required: true

  def mono(assigns) do
    ~H"""
    <span class="text-th-primary font-mono">{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  A short explanation sitting above or beside content.

  `:info` is for a state that is not a fault — a subsystem switched off, a kind
  that has no entity state, a result the limit truncated. `:error` is for a
  failure. Keeping both in one component means the difference is a parameter
  rather than two blocks of markup that drifted.

  ## Examples

      <.notice kind={:info}>Audit logging is off on the controller.</.notice>
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
      class={[
        "flex items-start gap-3 px-4 py-3 rounded-xl border text-sm",
        @kind == :info && "border-brd bg-surface-input text-th-secondary",
        @kind == :error &&
          "bg-[var(--color-danger-subtle-bg)] border-[var(--color-danger-subtle-border)] text-danger-text",
        @class
      ]}
    >
      <.icon name={@resolved_icon} class="w-5 h-5 shrink-0 mt-px" />
      <p>{render_slot(@inner_block)}</p>
    </div>
    """
  end

  defp notice_icon(_kind, icon) when is_binary(icon), do: icon
  defp notice_icon(:error, _icon), do: "hero-exclamation-triangle"
  defp notice_icon(:info, _icon), do: "hero-information-circle"

  @doc """
  Renders a banner for a normalised `FlezhaUi.Service.NodeManager` error.

  Renders nothing when `error` is `nil`, so a screen can pass its last call
  result unconditionally.

  ## Examples

      <.runtime_error error={@load_error} />
  """
  attr :error, :any, default: nil, doc: "a normalised NodeManager error, or nil"
  attr :class, :string, default: nil

  def runtime_error(assigns) do
    assigns = assign(assigns, :message, runtime_error_message(assigns.error))

    ~H"""
    <.notice :if={@message} kind={:error} testid="runtime-error" class={@class}>
      {@message}
    </.notice>
    """
  end

  defp runtime_error_message(nil), do: nil

  defp runtime_error_message(:node_not_connected) do
    "Not connected to a flezha controller. Screens will recover automatically once it is reachable."
  end

  defp runtime_error_message({:api_missing, module, function, arity}) do
    "This UI and the flezha controller have diverged: the controller does not export " <>
      "#{inspect(module)}.#{function}/#{arity}."
  end

  defp runtime_error_message(:timeout) do
    "The flezha controller did not answer in time."
  end

  defp runtime_error_message({:remote_error, reason}) do
    "The flezha controller reported an error: #{inspect(reason)}"
  end

  defp runtime_error_message(reason), do: "Error: #{inspect(reason)}"

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
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
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-2 right-2 mr-2 w-80 sm:w-96 z-50 rounded-lg p-3 ring-1",
        @kind == :info && "bg-emerald-50 text-emerald-800 ring-emerald-500 fill-cyan-900",
        @kind == :error && "bg-rose-50 text-rose-900 shadow-md ring-rose-500 fill-rose-900"
      ]}
      {@rest}
    >
      <p :if={@title} class="flex items-center gap-1.5 text-sm font-semibold leading-6">
        <.icon :if={@kind == :info} name="hero-information-circle-mini" class="h-4 w-4" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle-mini" class="h-4 w-4" />
        {@title}
      </p>
      <p class="mt-2 text-sm leading-5">{msg}</p>
      <button type="button" class="group absolute top-1 right-1 p-2" aria-label={gettext("close")}>
        <.icon name="hero-x-mark-solid" class="h-5 w-5 opacity-40 group-hover:opacity-70" />
      </button>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} title={gettext("Success!")} flash={@flash} />
      <.flash kind={:error} title={gettext("Error!")} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Hang in there while we get back on track")}
        <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <.input field={@form[:username]} label="Username" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the data structure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div class="mt-10 space-y-8">
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="mt-2 flex items-center justify-between gap-6">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  Renders a button.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
      <.button variant="secondary" size="sm" icon="hero-plus">Add</.button>
      <.button variant="danger" loading={true}>Deleting...</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :variant, :string, default: "primary", values: ~w(primary secondary danger ghost outline)
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :icon, :string, default: nil
  attr :icon_right, :string, default: nil
  attr :loading, :boolean, default: false
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      disabled={@loading}
      class={[
        "phx-submit-loading:opacity-75 inline-flex items-center justify-center gap-2 rounded-xl font-semibold leading-6",
        "hover:scale-[1.02] active:scale-[0.98] transition-all duration-200 ease-out",
        "focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2",
        "disabled:opacity-50 disabled:pointer-events-none",
        button_size_classes(@size),
        button_variant_classes(@variant),
        @class
      ]}
      {@rest}
    >
      <span :if={@loading} class="hero-arrow-path h-4 w-4 animate-spin" />
      <span :if={@icon && !@loading} class={[@icon, icon_size(@size)]} />
      {render_slot(@inner_block)}
      <span :if={@icon_right} class={[@icon_right, icon_size(@size)]} />
    </button>
    """
  end

  defp button_variant_classes("primary"),
    do: "bg-accent hover:bg-accent-hover text-white hover:shadow-btn-hover"

  defp button_variant_classes("secondary"),
    do: "bg-surface-input border border-brd text-th-secondary hover:bg-surface-hover"

  defp button_variant_classes("danger"), do: "bg-danger hover:bg-danger-hover text-white"

  defp button_variant_classes("ghost"),
    do: "text-th-tertiary hover:text-th-primary hover:bg-surface-hover"

  defp button_variant_classes("outline"),
    do: "border border-accent text-accent-text hover:bg-accent hover:text-white"

  defp button_size_classes("sm"), do: "py-1.5 px-2.5 text-xs"
  defp button_size_classes("md"), do: "py-2 px-3 text-sm"
  defp button_size_classes("lg"), do: "py-2.5 px-5 text-base"

  defp icon_size("sm"), do: "h-3.5 w-3.5"
  defp icon_size("md"), do: "h-4 w-4"
  defp icon_size("lg"), do: "h-5 w-5"

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
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

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <label class="flex items-center gap-4 text-sm leading-6 text-th-secondary">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="rounded border-brd-input text-accent focus:ring-0 bg-surface-input"
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
    <div>
      <.label for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class="mt-2 block w-full rounded-xl border border-brd-input bg-surface-input text-th-primary shadow-sm focus:border-brd-focus focus:ring-0 focus-visible:ring-2 focus-visible:ring-accent/50 focus-visible:ring-offset-1 sm:text-sm"
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "mt-2 block w-full rounded-xl bg-surface-input text-th-primary focus:ring-0 focus-visible:ring-2 focus-visible:ring-accent/50 focus-visible:ring-offset-1 sm:text-sm sm:leading-6 min-h-[6rem]",
          @errors == [] && "border-brd-input focus:border-brd-focus",
          @errors != [] && "border-danger focus:border-danger"
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "mt-2 block w-full rounded-xl bg-surface-input text-th-primary focus:ring-0 focus-visible:ring-2 focus-visible:ring-accent/50 focus-visible:ring-offset-1 sm:text-sm sm:leading-6",
          @errors == [] && "border-brd-input focus:border-brd-focus",
          @errors != [] && "border-danger focus:border-danger"
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders a label.
  """
  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class="block text-sm font-semibold leading-6 text-th-primary">
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc """
  Generates a generic error message.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-3 flex gap-3 text-sm leading-6 text-danger-text">
      <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-5 w-5 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  attr :class, :string, default: nil

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", @class]}>
      <div>
        <h1 class="text-lg font-semibold leading-8 text-th-primary">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-2 text-sm leading-6 text-th-tertiary">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc ~S"""
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-y-auto px-4 sm:overflow-visible sm:px-0">
      <table class="w-[40rem] mt-11 sm:w-full">
        <thead class="text-sm text-left leading-6 text-th-tertiary">
          <tr>
            <th :for={col <- @col} class="p-0 pb-4 pr-6 font-normal">{col[:label]}</th>
            <th :if={@action != []} class="relative p-0 pb-4">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
          class="relative divide-y divide-brd-subtle border-t border-brd text-sm leading-6 text-th-secondary"
        >
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="group hover:bg-surface-hover">
            <td
              :for={{col, i} <- Enum.with_index(@col)}
              phx-click={@row_click && @row_click.(row)}
              class={["relative p-0", @row_click && "hover:cursor-pointer"]}
            >
              <div class="block py-4 pr-6">
                <span class="absolute -inset-y-px right-0 -left-4 group-hover:bg-surface-hover sm:rounded-l-xl" />
                <span class={["relative", i == 0 && "font-semibold text-th-primary"]}>
                  {render_slot(col, @row_item.(row))}
                </span>
              </div>
            </td>
            <td :if={@action != []} class="relative w-14 p-0">
              <div class="relative whitespace-nowrap py-4 text-right text-sm font-medium">
                <span class="absolute -inset-y-px -right-4 left-0 group-hover:bg-surface-hover sm:rounded-r-xl" />
                <span
                  :for={action <- @action}
                  class="relative ml-4 font-semibold leading-6 text-accent-text hover:text-accent"
                >
                  {render_slot(action, @row_item.(row))}
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <div class="mt-14">
      <dl class="-my-4 divide-y divide-brd-subtle">
        <div :for={item <- @item} class="flex gap-4 py-4 text-sm leading-6 sm:gap-8">
          <dt class="w-1/4 flex-none text-th-tertiary">{item.title}</dt>
          <dd class="text-th-secondary">{render_slot(item)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc """
  Renders a back navigation link.

  ## Examples

      <.back navigate={~p"/posts"}>Back to posts</.back>
  """
  attr :navigate, :any, required: true
  slot :inner_block, required: true

  def back(assigns) do
    ~H"""
    <div class="mt-16">
      <.link
        navigate={@navigate}
        class="text-sm font-semibold leading-6 text-accent-text hover:text-accent"
      >
        <.icon name="hero-arrow-left-solid" class="h-3 w-3" />
        {render_slot(@inner_block)}
      </.link>
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in your `assets/tailwind.config.js`.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 300,
      transition: {"transition-all transform ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
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
