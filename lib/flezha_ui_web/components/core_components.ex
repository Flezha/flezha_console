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

  # Refusals link to where a token is stored, so the components need routes.
  use Phoenix.VerifiedRoutes,
    endpoint: FlezhaUiWeb.Endpoint,
    router: FlezhaUiWeb.Router,
    statics: FlezhaUiWeb.static_paths()

  alias FlezhaUi.Format
  alias FlezhaUi.Service.NodeManager
  alias Phoenix.LiveView.JS

  @doc """
  The overlay and panel every dialog on the operator screens sits in.

  Padded and scrollable, so a panel taller than the viewport can still be
  reached — a provider declaring many fields makes one.

  A `:title` slot heads the dialog and, with `on_close`, gives it the dismiss
  control — so the heading and its close button are one decision rather than
  one per modal.

  ## Examples

      <.dialog :if={@open} testid="start-modal" size="form" on_close="close_start">
        <:title>Start a relay</:title>
        ...
      </.dialog>
  """
  attr :testid, :string, default: nil

  attr :size, :string,
    default: "confirm",
    values: ~w(confirm form wide),
    doc: "what the dialog is for; the width follows from it"

  attr :on_close, :string,
    default: nil,
    doc: "the event the header's dismiss control sends; without it there is no control"

  attr :close_testid, :string, default: nil
  slot :title
  slot :actions, doc: "controls in the dialog foot, right-aligned"
  slot :inner_block, required: true

  def dialog(assigns) do
    ~H"""
    <div class="flz-modal">
      <div data-testid={@testid} class={["flz-modal-surface", width(@size)]}>
        <div :if={@title != []} class="flz-modal-head">
          <h3 class="flz-modal-title">{render_slot(@title)}</h3>
          <button
            :if={@on_close}
            phx-click={@on_close}
            data-testid={@close_testid}
            class="flz-button flz-button--sm flz-button--ghost"
            aria-label={gettext("close")}
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
        <div class="flz-modal-body">{render_slot(@inner_block)}</div>
        <div :if={@actions != []} class="flz-modal-foot">{render_slot(@actions)}</div>
      </div>
    </div>
    """
  end

  # Widths, once. A form dialog is wider than a confirmation because it has
  # fields to read; an inspection panel is wider still because it carries a
  # payload. Callers name the role so this stays one decision rather than one
  # per modal.
  defp width("confirm"), do: "max-w-md"
  defp width("form"), do: "max-w-xl"
  defp width("wide"), do: "max-w-3xl"

  @doc """
  A dialog asking the operator to confirm an action before it happens.

  Used for every irreversible verb on these screens, so they all ask the same
  way. `values` are sent with the confirm click, for a handler keyed on which
  row was acted on.

  ## Examples

      <.confirm_dialog
        :if={@confirm_stop}
        title="Stop relay?"
        confirm_label="Stop"
        on_confirm="stop_relay"
        on_cancel="cancel_stop"
        values={%{"relay_id" => @confirm_stop}}
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
    <.dialog testid={@testid} size="confirm">
      <:title>{@title}</:title>
      <p>{render_slot(@inner_block)}</p>
      <:actions>
        <button
          phx-click={@on_cancel}
          data-testid={@cancel_testid}
          class="flz-button flz-button--md flz-button--ghost"
        >
          Cancel
        </button>
        <button
          phx-click={@on_confirm}
          {values_attrs(@values)}
          data-testid={@confirm_testid}
          class={"flz-button flz-button--md flz-button--#{@variant}"}
        >
          {@confirm_label}
        </button>
      </:actions>
    </.dialog>
    """
  end

  defp values_attrs(values) do
    Map.new(values, fn {key, value} -> {"phx-value-#{key}", value} end)
  end

  @ui_lockup Path.expand(
               "../../../priv/static/images/flezha-ui-badger-line-text-white.svg",
               __DIR__
             )
  @external_resource @ui_lockup

  # The stylebook's logo rule is square; this lockup is not, so its proportions
  # are read from its own viewBox rather than copied by hand.
  @ui_lockup_aspect (case Regex.run(~r/viewBox="\S+ \S+ (\S+) (\S+)"/, File.read!(@ui_lockup)) do
                       [_, width, height] -> "#{width} / #{height}"
                     end)

  @doc """
  The Flezha UI lockup: the stylebook's badger over the FLEZHA name with UI
  beside it, painted as a mask so it takes the ink of whatever it sits on.

  On the chrome it takes the chrome's ink; on the content canvas it takes the
  brand ink, so one lockup serves every surface and theme with no image swap.

  ## Examples

      <.brand_lockup on={:chrome} />
  """
  attr :on, :atom, default: :canvas, values: [:chrome, :canvas]

  def brand_lockup(assigns) do
    ~H"""
    <span class={["flz-brand", @on == :canvas && "text-th-brand"]}>
      <span
        role="img"
        aria-label="Flezha UI"
        class={["flz-logo", @on == :canvas && "h-10"]}
        style={"mask-image: url(#{~p"/images/flezha-ui-badger-line-text-white.svg"}); aspect-ratio: #{ui_lockup_aspect()}"}
      >
      </span>
    </span>
    """
  end

  defp ui_lockup_aspect, do: @ui_lockup_aspect

  @doc """
  An identifier rendered the way identifiers are rendered everywhere here.
  """
  slot :inner_block, required: true

  def mono(assigns) do
    ~H"""
    <span class="flz-num text-th-primary">{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  A short explanation sitting above or beside content.

  `:info` is for a state that is not a fault — a subsystem switched off, a kind
  that has no cell state, a result the limit truncated. `:error` is for a
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
        "flz-toast",
        @kind == :info && "flz-toast--info",
        @kind == :error && "flz-toast--negative",
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
  result unconditionally. A controller error links to its code's family in
  core's errors reference; a condition only this node sees has no code there
  and no link. A diagnosis finding has the same shape and renders here too,
  as `:info` when it is only a note.

  ## Examples

      <.runtime_error error={@load_error} />
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
      {error_message(@error, @action)}
      <span :if={@error.hint} class="block text-xs" data-testid="runtime-error-hint">
        {@error.hint}
      </span>
      <a
        :if={reference_url(@error.code)}
        href={reference_url(@error.code)}
        target="_blank"
        rel="noopener noreferrer"
        data-testid="runtime-error-reference"
        class="block text-xs underline hover:no-underline"
      >
        What {@error.code} means
      </a>
      <.link
        :if={@settings_link?}
        navigate={~p"/users/settings"}
        class="underline hover:no-underline"
      >
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
    <.notice :if={is_binary(@error)} kind={:error} testid={@testid} class="mb-4">
      {@error}
    </.notice>
    <div :if={@error && !is_binary(@error)} data-testid={@testid} class="mb-4">
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

  def error_message(%{class: :denied, code: code, message: message}, action),
    do: "The controller refused #{action || "this call"}: #{message} (#{code})"

  def error_message(%{code: "ui." <> _, message: message}, _action), do: message
  def error_message(%{code: code, message: message}, _action), do: "#{message} (#{code})"
  def error_message(error, action), do: error_message(NodeManager.error(error), action)

  @doc """
  A titled section of a screen, in the standard panel chrome.

  The header carries an icon and the title; `:actions` puts controls on its
  right. The body is the default slot, undecorated — a table, a list or an
  empty-state paragraph fills it.

      <.panel testid="role-bindings" icon="hero-key" class="overflow-hidden">
        <:title>Role bindings ({length(@role_bindings)})</:title>
        <table>...</table>
      </.panel>

  Every panel on every screen is drawn here, so the chrome is one decision
  rather than one per section.

  Naming a `fold` turns the title into the control that folds the panel shut —
  what the lower reaches of a long screen open on. The open state is the
  screen's own assign (`FlezhaUiWeb.Live.Sections`) so the server renders the
  truth on first paint; the `FlzSection` hook restores the viewer's own last
  choice over it. Whatever the head carries beside the title stays its own
  control, outside the fold button.

      <.panel fold="journal" open={@sections["journal"]} icon="hero-book-open">
        <:title>Proc journal</:title>
        <table>...</table>
      </.panel>
  """
  attr :testid, :string, default: nil
  attr :icon, :string, default: nil, doc: "a heroicon name, or nil for a panel with no icon"
  attr :class, :string, default: nil

  attr :fold, :string,
    default: nil,
    doc: "the key this panel folds and is stored under; without it there is no fold"

  attr :id, :string, default: nil, doc: "defaults to the fold key, which is unique per screen"
  attr :open, :boolean, default: true, doc: "meaningful only with a fold"

  attr :forced, :boolean,
    default: false,
    doc: "true when the screen opened this itself, over both the default and the stored choice"

  slot :title, required: true
  slot :actions, doc: "controls rendered at the right of the header"
  slot :inner_block, required: true

  def panel(assigns) do
    # Not `assign_new/3`: the attribute is always present, defaulted to nil.
    assigns = assign(assigns, :id, assigns.id || assigns.fold)

    ~H"""
    <div
      id={@id}
      phx-hook={@fold && "FlzSection"}
      data-testid={@testid}
      data-open={@fold && to_string(@open)}
      data-section-key={@fold}
      data-section-forced={@fold && to_string(@forced)}
      class={["flz-panel", @class]}
    >
      <div class="flz-panel-head">
        <button
          :if={@fold}
          type="button"
          class="flz-panel-fold"
          aria-expanded={to_string(@open)}
          aria-controls={"#{@id}-body"}
          phx-click="section_toggle"
          phx-value-key={@fold}
          data-testid={"section-toggle-#{@fold}"}
        >
          <.icon name="hero-chevron-right-micro" class="flz-fold-mark" />
          <.panel_title icon={@icon}>{render_slot(@title)}</.panel_title>
        </button>
        <.panel_title :if={!@fold} icon={@icon}>{render_slot(@title)}</.panel_title>
        <div :if={@actions != []} class="flex items-center gap-3">
          {render_slot(@actions)}
        </div>
      </div>
      <%= if @fold do %>
        <div :if={@open} id={"#{@id}-body"} data-testid={"section-body-#{@fold}"}>
          {render_slot(@inner_block)}
        </div>
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </div>
    """
  end

  attr :icon, :string, default: nil
  slot :inner_block, required: true

  defp panel_title(assigns) do
    ~H"""
    <h2 class="flz-panel-title">
      <.icon :if={@icon} name={@icon} class="w-4 h-4" />
      {render_slot(@inner_block)}
    </h2>
    """
  end

  @doc """
  What a screen shows in place of a listing that has nothing in it.

  `boxed` is for a section that stands on its own; the default sits inside a
  `panel/1` whose chrome is already drawn. Every "nothing here" on every screen
  reads the same way, rather than drifting one copy-paste at a time.

      <.empty_state icon="hero-clock" testid="schedule-empty">
        No schedule has been created.
      </.empty_state>
  """
  attr :icon, :string, required: true
  attr :testid, :string, default: nil
  attr :boxed, :boolean, default: false, doc: "true for a section with no panel around it"

  slot :inner_block, required: true
  slot :detail, doc: "a second line, for what the operator might do about it"

  def empty_state(assigns) do
    ~H"""
    <div data-testid={@testid} class={["flz-empty", @boxed && "flz-panel"]}>
      <.icon name={@icon} class="flz-empty-icon w-10 h-10 block" />
      <p>{render_slot(@inner_block)}</p>
      <p :if={@detail != []}>{render_slot(@detail)}</p>
    </div>
    """
  end

  @doc """
  One labelled figure in a grid of them — the shape every facts panel is made
  of.

  Belongs inside a `<dl>`, which is what the grid around it is. `tone` carries
  the value's own treatment: the default is the mono figure, and `nil` is for a
  value that brings its own markup, such as a badge.

      <dl class="grid grid-cols-3 gap-4 text-sm">
        <.stat label="Uptime" testid="relay-uptime">{Format.duration(@uptime_ms)}</.stat>
      </dl>
  """
  attr :label, :any, required: true
  attr :testid, :string, default: nil

  attr :tone, :string,
    default: nil,
    doc: "classes overriding the value's own treatment, such as a semantic colour"

  attr :boxed, :boolean,
    default: false,
    doc: "true for a figure that brings its own tile, in a summary strip"

  slot :inner_block, required: true

  def stat(assigns) do
    ~H"""
    <div class={["flz-stat", @boxed && "flz-stat--boxed"]}>
      <dt>{@label}</dt>
      <dd data-testid={@testid} class={@tone}>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @doc """
  Whether this UI holds a connection to the controller, as a dot.

  Live is a pulse rather than a static mark, because the thing it reports is a
  connection that can drop while the page is open.
  """
  attr :connected?, :boolean, required: true
  attr :size, :string, default: "h-2 w-2"
  attr :class, :string, default: nil

  def status_dot(assigns) do
    ~H"""
    <span :if={@connected?} class={["relative flex", @size, @class]}>
      <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-75">
      </span>
      <span class={["relative inline-flex rounded-full bg-success", @size]}></span>
    </span>
    <span :if={!@connected?} class={["rounded-full bg-danger", @size, @class]}></span>
    """
  end

  @doc """
  A relay's health, as the Convergence Loop classified it.

  Every value gets its own colour, `:unknown` included — a row the loop has not
  observed is not a healthy row, and rendering it like one would hide the case
  the column exists for.
  """
  attr :health, :any, required: true
  attr :count, :any, default: nil, doc: "how many rows carry this health, for a rollup"
  attr :class, :string, default: nil

  def health_badge(assigns) do
    ~H"""
    <span
      data-testid="health-badge"
      data-health={@health}
      class={["flz-badge", health_variant(@health), @class]}
    >
      <span class="flz-badge-dot"></span>
      <span :if={not is_nil(@count)} class="flz-num">{@count}</span>
      {@health}
    </span>
    """
  end

  # The dot takes the badge's own ink, so one variant colours both.
  defp health_variant(:healthy), do: "flz-badge--positive"
  defp health_variant(:degraded), do: "flz-badge--warning"
  defp health_variant(:unbound), do: "flz-badge--warning"
  defp health_variant(:failed), do: "flz-badge--negative"
  # Unknown, and suspended — parked at a committed boundary with no runner, so
  # neither running nor broken — are no outcome: the plain badge, named by its
  # word.
  defp health_variant(_health), do: nil

  @doc """
  The controller's authorization posture, as a banner.

  Renders nothing when there is nothing an operator needs to act on: an open
  controller, or an enforced one with a bound principal. A posture the
  controller could not be asked for renders nothing either — the disconnected
  indicator already says why.
  """
  attr :status, :map, required: true, doc: "a `NodeManager.authz_status/1` map"

  def authz_banner(assigns) do
    ~H"""
    <.notice
      :if={@status.posture == :bootstrap_pending}
      kind={:error}
      testid="authz-bootstrap-pending"
      class="mb-4"
    >
      Authorization is enforced on this controller but has not been claimed. Run
      <code class="font-mono">flz auth bootstrap &lt;token&gt;</code>
      on the controller to claim it; until then every operator verb is refused.
    </.notice>

    <.notice
      :if={@status.posture == :enforced and is_nil(@status.principal)}
      kind={:error}
      testid="authz-unbound"
      class="mb-4"
    >
      <span :if={@status.token?}>
        The flezha token this UI presents did not bind an identity — {@status.reason &&
          error_message(@status.reason)}
      </span>
      <span :if={!@status.token?}>
        No flezha token is bound to this UI.
      </span>
      Reads of the audit log and observability, and every mutation, will be refused.
      <.link navigate={~p"/users/settings"} class="underline hover:no-underline">
        Store a token in settings.
      </.link>
    </.notice>
    """
  end

  @doc """
  The bound principal, its namespace scope and its role, for the top bar.

  Absent rather than guessed when nothing is bound — `authz_banner/1` is what
  says so.
  """
  attr :status, :map, required: true, doc: "a `NodeManager.authz_status/1` map"

  def authz_identity(assigns) do
    ~H"""
    <span
      :if={@status.principal}
      data-testid="authz-identity"
      class="flz-num flz-topbar-muted flex items-center gap-1.5 text-xs"
      title={"flezha principal #{@status.principal}"}
    >
      <.icon name="hero-key" class="w-3.5 h-3.5" />
      {@status.principal}
      <span :if={@status.namespace}>/{@status.namespace}</span>
      <span :if={@status.role}>({@status.role})</span>
    </span>
    """
  end

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
        "flz-toast",
        @kind == :info && "flz-toast--positive",
        @kind == :error && "flz-toast--negative"
      ]}
      {@rest}
    >
      <.icon :if={@kind == :info} name="hero-information-circle-mini" class="h-4 w-4 shrink-0" />
      <.icon :if={@kind == :error} name="hero-exclamation-circle-mini" class="h-4 w-4 shrink-0" />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="font-semibold text-th-primary">{@title}</p>
        <p>{msg}</p>
      </div>
      <button type="button" class="group shrink-0" aria-label={gettext("close")}>
        <.icon name="hero-x-mark-solid" class="h-4 w-4 opacity-40 group-hover:opacity-70" />
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
    <div id={@id} class="flz-toast-stack">
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
  Renders a button.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
      <.button variant="secondary" size="sm" icon="hero-plus">Add</.button>
      <.button variant="danger" loading={true}>Deleting...</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :variant, :string, default: "primary", values: ~w(primary secondary danger ghost accent)
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :icon, :string, default: nil
  attr :icon_right, :string, default: nil
  attr :loading, :boolean, default: false
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block, required: true

  def button(assigns) do
    # A button with its own click handler is an action, not a submit: inside a
    # form an untyped button submits it, so a dialog's Cancel would also send
    # the form it cancels.
    assigns = assign(assigns, :type, assigns.type || if(assigns.rest[:"phx-click"], do: "button"))

    ~H"""
    <button
      type={@type}
      disabled={@loading}
      class={[
        "phx-submit-loading:opacity-75 flz-button flz-button--#{@size}",
        @variant != "primary" && "flz-button--#{@variant}",
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

  defp icon_size("sm"), do: "h-3.5 w-3.5"
  defp icon_size("md"), do: "h-4 w-4"
  defp icon_size("lg"), do: "h-5 w-5"

  @doc """
  A dropdown that picks one value.

  For a picker — a filter, a namespace switch — where the OS-drawn menu of a
  native `select` cannot be styled to match. Form fields keep their `select`,
  which is the better control inside a dialog.

  The value lives in a hidden input under the enclosing form's own name, so the
  form's `phx-change` fires with exactly the params a `select` would have sent
  and no event handler changes. Opening, closing and the keyboard come from the
  stylebook's `initDropdowns()`.

  ## Examples

      <.dropdown id="ns" name="filters[namespace]" value={@filters["namespace"]} prompt="all">
        <:option value="">all</:option>
        <:option :for={ns <- @namespaces} value={ns}>{ns}</:option>
      </.dropdown>
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :prompt, :string, default: nil, doc: "shown when the value matches no option"
  attr :testid, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :class, :string, default: nil

  slot :option, required: true do
    attr :value, :string, required: true
  end

  def dropdown(assigns) do
    value = to_string(assigns.value || "")

    assigns =
      assigns
      |> assign(:value, value)
      |> assign(:chosen, Enum.find(assigns.option, &(&1.value == value)))

    ~H"""
    <div class="flz-field">
      <.label :if={@label}>{@label}</.label>
      <div id={@id} phx-hook="FlzDropdown" data-flz-dropdown class={["relative", @class]}>
        <input type="hidden" id={"#{@id}-value"} name={@name} value={@value} />
        <button
          type="button"
          class="flz-dropdown-trigger form-field--compact w-full"
          data-testid={@testid}
          disabled={@disabled}
        >
          <span class="flex-1 truncate text-left">
            {(@chosen && render_slot(@chosen)) || @prompt}
          </span>
          <.icon name="hero-chevron-down-micro" class="shrink-0" />
        </button>
        <div class="flz-dropdown mt-1 min-w-full" role="menu" hidden>
          <button
            :for={option <- @option}
            type="button"
            role="menuitemradio"
            aria-checked={to_string(option.value == @value)}
            data-testid={@testid && "#{@testid}-#{option.value}"}
            phx-click={
              JS.set_attribute({"value", option.value}, to: "##{@id}-value")
              |> JS.dispatch("change", to: "##{@id}-value", bubbles: true)
            }
            class="flz-dropdown-option"
          >
            {render_slot(option)}
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The one labelled form control on these screens: label, control, hint, errors.

  Every form field goes through here, so the control's styling — its size, its
  focus ring, its border — is one decision rather than one per template. A
  template that hand-writes a label and an `<input>` beside it is a bug.

  A `Phoenix.HTML.FormField` may be passed as argument, which is used to
  retrieve the input name, id, and values. Otherwise all attributes may be
  passed explicitly, which is what the operator screens do: their forms are
  plain maps against the controller, not changesets.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  `data-testid` rides the global attributes through to the control itself, so a
  browser test addresses the input rather than the wrapper.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
      <.input
        type="textarea"
        name="start[init_values]"
        label="Init values"
        hint="JSON, optional"
        mono
        value={@form["init_values"]}
        data-testid="input-init-values"
      />
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

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="flz-field">
      <label class="flz-field-label gap-4">
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
    <div class="flz-field">
      <.label :if={@label} for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={["block w-full", @mono && "form-field--mono", @compact && "form-field--compact"]}
        aria-invalid={@errors != [] && "true"}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint} class="flz-field-hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="flz-field">
      <.label :if={@label} for={@id}>{@label}</.label>
      <%!-- Tall enough to read a small JSON object whole: an editor that
            scrolls at three lines is why init values were guessed at. --%>
      <textarea
        id={@id}
        name={@name}
        class={["block w-full min-h-[8rem]", @mono && "form-field--mono"]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="flz-field-hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="flz-field">
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={["block w-full", @mono && "form-field--mono", @compact && "form-field--compact"]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <p :if={@hint} class="flz-field-hint">{@hint}</p>
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
    <label for={@for} class="flz-field-label">
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
    <p class="flz-field-error">
      <.icon name="hero-exclamation-circle-mini" class="h-4 w-4 flex-none" />
      {render_slot(@inner_block)}
    </p>
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

  ## Examples

      <.enumerated_field
        name="binding[role]"
        label="Role"
        value={@form["role"]}
        options={Enum.map(@roles, &{&1, &1})}
        prompt="Select a role..."
        empty="The controller declares no roles"
        error={@roles_error}
        testid="input-role"
      />
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
      hint={"The choices could not be read (#{inspect(@error)}) — type a value instead."}
      mono={@mono}
      data-testid={@testid}
    />
    """
  end

  @doc """
  A screen's heading, with controls beside it.

  Every screen opens with one, so the title's type and the action row are one
  decision rather than one per screen. Where the screen sits is the shell's
  business — the crumb trail says it, in words, above this.

  ## Examples

      <.header mono>
        {@ns}
        <:actions><.button icon="hero-plus">Start Relay</.button></:actions>
      </.header>
  """
  attr :class, :string, default: nil

  attr :mono, :boolean, default: false, doc: "true when the title is an identifier"

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={["flex items-center justify-between gap-6", @class]}>
      <div>
        <h1 class={["flz-title-lg text-th-primary", @mono && "flz-num"]}>
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-2 text-sm text-th-secondary">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Where the current screen sits, as a trail of its ancestors.

  Derived by the shell from the route (`FlezhaUiWeb.Layouts.breadcrumbs/1`), so
  it is one derivation rather than one per screen. The last crumb is the page
  being read: plain text, marked current, and not a link to itself.
  """
  attr :trail, :list, required: true

  def breadcrumb(assigns) do
    ~H"""
    <nav
      :if={@trail != []}
      aria-label="Breadcrumb"
      data-testid="breadcrumb"
      class="flz-breadcrumb mb-5"
    >
      <%= for {crumb, index} <- Enum.with_index(@trail) do %>
        <span :if={index > 0} class="flz-breadcrumb-sep" aria-hidden="true">/</span>
        <.link :if={crumb.path} navigate={crumb.path} class="flz-breadcrumb-item">
          {crumb.label}
        </.link>
        <span :if={!crumb.path} class="flz-breadcrumb-item" aria-current="page">
          {crumb.label}
        </span>
      <% end %>
    </nav>
    """
  end

  @doc """
  The views of one object, as a strip of tabs on it.

  Each tab is its own route, and selecting one navigates: a relay's Detail
  polls overwatch, its Listen holds a live listener and its State does
  point-in-time reads, so collapsing them into one screen would leave a
  listener attached while the operator reads something else. The strip makes
  them read as one object without making them one process.

      <.relay_tabs ns={@ns} relay_id={@relay_id} current={:listen} />
  """
  attr :ns, :string, required: true
  attr :relay_id, :string, required: true
  attr :current, :atom, required: true, values: [:detail, :listen, :state]

  def relay_tabs(assigns) do
    ~H"""
    <nav class="flz-tabstrip" data-testid="relay-tabs" aria-label="Relay views">
      <.link
        :for={{view, label, path} <- relay_views(@ns, @relay_id)}
        navigate={path}
        aria-current={view == @current && "page"}
        data-testid={"relay-tab-#{view}"}
        class="flz-tabstrip-link"
      >
        {label}
      </.link>
    </nav>
    """
  end

  defp relay_views(ns, id) do
    [
      {:detail, "Detail", ~p"/namespaces/#{ns}/relays/#{id}"},
      {:listen, "Listen", ~p"/namespaces/#{ns}/relays/#{id}/listen"},
      {:state, "State", ~p"/namespaces/#{ns}/relays/#{id}/state"}
    ]
  end

  @doc """
  A trigger and a panel of things to do, on the stylebook's menu recipe.

  For a set of actions rather than a set of values — the account controls, the
  namespace to scope to. `dropdown/1` is the one to reach for when the panel
  picks a value for a form; this one holds whatever rows the caller writes,
  which is what lets an identity line, a separator and a sign-out sit together.

  Opening, closing and the keyboard come from the same `FlzDropdown` hook.

      <.menu id="account-menu" testid="account-menu">
        <:trigger>you@example.com</:trigger>
        <.link navigate={~p"/users/settings"} class="flz-menu-item">Settings</.link>
      </.menu>
  """
  attr :id, :string, required: true
  attr :testid, :string, default: nil
  attr :label, :string, default: nil, doc: "what the trigger is called, for a screen reader"

  slot :trigger, required: true
  slot :inner_block, required: true

  def menu(assigns) do
    ~H"""
    <div id={@id} phx-hook="FlzDropdown" data-flz-dropdown class="relative">
      <button
        type="button"
        class="flz-dropdown-trigger flz-chrome-icon-btn"
        data-testid={@testid}
        aria-label={@label}
      >
        {render_slot(@trigger)}
        <.icon name="hero-chevron-down-micro" class="shrink-0" />
      </button>
      <div class="flz-dropdown flz-menu mt-1" role="menu" hidden>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Why a scoped listing's count is not a controller-side guarantee.

  The controller answers the listing whole, so the screen fetches all of it and
  narrows the rows here, and says so rather than implying a controller-side
  scope.
  """
  attr :scope, :string, required: true
  attr :listing, :string, required: true, doc: "the noun the controller answers globally"
  attr :testid, :string, default: nil

  def scope_notice(assigns) do
    ~H"""
    <.notice testid={@testid}>
      The controller has no namespaced {@listing} listing, so <span class="flz-num">{@scope}</span>
      is applied here as a view filter over its full listing rather than as a
      controller-side scope.
    </.notice>
    """
  end

  @doc """
  What a screen says about its own currency: that it refreshes, when it last
  did, and the control to hold it still.

  Rendered by the shell for any screen that `use`s `FlezhaUiWeb.Live.Refresh`,
  which is what puts the assigns here — so a screen states its liveness by
  refreshing at all, rather than by remembering to say so.
  """
  attr :interval, :integer, required: true
  attr :at, :any, default: nil, doc: "when the last refresh landed, or nil before the first"
  attr :paused, :boolean, required: true

  def liveness(assigns) do
    ~H"""
    <div data-testid="liveness" class="flex items-center gap-2">
      <span class="flz-topbar-muted" data-testid="liveness-state">
        <span :if={@paused}>Paused</span>
        <span :if={!@paused}>
          Every {Format.duration(@interval)} · {Format.time_of_day(@at)}
        </span>
      </span>
      <button
        type="button"
        phx-click="refresh_toggle"
        aria-pressed={to_string(@paused)}
        data-testid="liveness-toggle"
        class="flz-chrome-icon-btn"
        title={if @paused, do: "Resume refreshing", else: "Pause refreshing"}
        aria-label={if @paused, do: "Resume refreshing", else: "Pause refreshing"}
      >
        <.icon :if={@paused} name="hero-play" class="w-4 h-4" />
        <.icon :if={!@paused} name="hero-pause" class="w-4 h-4" />
      </button>
    </div>
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
    <div class="table-scroll">
      <table class="flz-table">
        <thead>
          <tr>
            <th :for={col <- @col}>{col[:label]}</th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={@row_click && "cursor-pointer"}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-14 whitespace-nowrap text-right">
              <span
                :for={action <- @action}
                class="ml-4"
              >
                {render_slot(action, @row_item.(row))}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
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
