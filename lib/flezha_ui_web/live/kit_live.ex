defmodule FlezhaUiWeb.KitLive do
  @moduledoc """
  Every component of the console's kit, in every variant and state, on one
  dev-only page — the target for checking the look in both themes. Routed
  only when `dev_routes` is enabled.
  """

  use FlezhaUiWeb, :live_view

  @healths FlezhaUi.Service.NodeManager.health_verdicts()

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Kit",
       switch_on: true,
       segment: "one",
       drawer?: false,
       dialog?: false,
       picked: "b",
       healths: @healths,
       samples: [0, 3, 2, 6, 4, 9, 7, 12, 8, 11]
     )}
  end

  @impl true
  def handle_event("kit_switch", _params, socket),
    do: {:noreply, update(socket, :switch_on, &(!&1))}

  def handle_event("kit_segment", %{"value" => value}, socket),
    do: {:noreply, assign(socket, segment: value)}

  def handle_event("kit_pick", %{"kit" => %{"pick" => value}}, socket),
    do: {:noreply, assign(socket, picked: value)}

  def handle_event("kit_drawer", _params, socket),
    do: {:noreply, update(socket, :drawer?, &(!&1))}

  def handle_event("kit_dialog", _params, socket),
    do: {:noreply, update(socket, :dialog?, &(!&1))}

  def handle_event("kit_flash", %{"kind" => kind}, socket) when kind in ~w(info error),
    do: {:noreply, put_flash(socket, String.to_existing_atom(kind), "An #{kind} toast.")}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header eyebrow="Dev" title="Component kit">
      <:sentence>
        Every element of the console's kit, in each variant and state. Flip the theme to check both.
      </:sentence>
      <:actions>
        <.button variant="secondary" data-flz-theme-toggle data-testid="kit-theme">
          Switch light and dark
        </.button>
      </:actions>
    </.page_header>

    <.section flush testid="kit-buttons">
      <:title>Buttons</:title>
      <div class="flex flex-wrap items-center gap-3">
        <.button :for={variant <- ~w(primary secondary ghost danger)} variant={variant}>
          {String.capitalize(variant)}
        </.button>
        <.button :for={variant <- ~w(primary secondary ghost danger)} variant={variant} size="sm">
          Small {variant}
        </.button>
        <.button icon="hero-plus">With icon</.button>
        <.button loading>Loading</.button>
        <.button disabled>Disabled</.button>
        <.button variant="secondary" aria-pressed="true">Pressed</.button>
        <.button variant="ghost" navigate="/dev/kit">As a link</.button>
      </div>
    </.section>

    <.section testid="kit-fields">
      <:title>Fields</:title>
      <form phx-change="kit_pick" class="grid gap-4 sm:grid-cols-2">
        <.input type="text" name="kit[text]" label="Text" hint="A hint" value="" placeholder="Type" />
        <.input type="text" name="kit[mono]" label="Mono" mono value="default_58efe7505741" />
        <.input type="text" name="kit[bad]" label="With an error" value="x" errors={["Not valid."]} />
        <.input type="text" name="kit[off]" label="Disabled" value="read only" disabled />
        <.input
          type="select"
          name="kit[select]"
          label="Select"
          value="b"
          options={[{"Alpha", "a"}, {"Beta", "b"}]}
        />
        <.input type="textarea" name="kit[area]" label="Textarea" value="{}" mono />
        <.input type="checkbox" name="kit[check]" label="Checkbox" value="true" />
        <.combobox
          id="kit-combobox"
          name="kit[pick]"
          label="Combobox"
          value={@picked}
          testid="kit-combobox"
        >
          <:option :for={value <- ~w(a b c d e f g h i j)} value={value}>Option {value}</:option>
        </.combobox>
      </form>
    </.section>

    <.section testid="kit-choices">
      <:title>Switch and segmented control</:title>
      <div class="flex flex-wrap items-center gap-6">
        <.switch checked={@switch_on} label="A switch" phx-click="kit_switch" testid="kit-switch" />
        <.switch checked={false} label="Off and disabled" disabled />
        <.segmented label="A choice" testid="kit-segmented">
          <:option
            :for={value <- ~w(one two three)}
            click="kit_segment"
            value={value}
            current={@segment == value}
          >
            {String.capitalize(value)}
          </:option>
        </.segmented>
      </div>
    </.section>

    <.section testid="kit-badges">
      <:title>Chips and state badges</:title>
      <div class="flex flex-wrap items-center gap-2">
        <.chip>a chip</.chip>
        <.chip mono>on_input</.chip>
        <.state_badge :for={health <- @healths} value={health} />
        <.state_badge value={:suspended} count={3} />
        <.state_badge kind={:readiness} value={:ready} />
        <.state_badge kind={:authz_posture} value={:open} />
        <.state_badge kind={:quota} value={:breached} />
        <span class="fui-live">Live</span>
      </div>
    </.section>

    <.section testid="kit-grid" digest="3 rows">
      <:title>Grid with row menus</:title>
      <.grid
        id="kit-grid-rows"
        rows={[
          %{id: "orders", health: :healthy},
          %{id: "testnet_echo", health: :suspended},
          %{id: "ledger", health: :failed}
        ]}
        row_tone={&Words.tone(:health, &1.health)}
        row_activate={&JS.push("kit_drawer", value: %{id: &1.id})}
        row_label={&"Inspect #{&1.id}"}
      >
        <:col :let={row} label="Relay"><.ident value={row.id} full /></:col>
        <:col :let={row} label="Health"><.state_badge value={row.health} /></:col>
        <:col :let={_row} label="Rate" num>
          <span class="fui-rate">4.2/s</span>
          <.sparkline samples={@samples} />
        </:col>
        <:menu :let={row}>
          <.row_menu id={"kit-menu-#{row.id}"} label={"Actions for #{row.id}"}>
            <:item click="kit_drawer" icon="hero-eye">Inspect</:item>
            <:item navigate="/dev/kit" icon="hero-arrow-top-right-on-square">Open</:item>
            <:item click="kit_dialog" danger icon="hero-stop">Stop</:item>
          </.row_menu>
        </:menu>
      </.grid>
    </.section>

    <.section testid="kit-figures">
      <:title>Figures</:title>
      <dl class="fui-facts">
        <.stat label="Plain">42</.stat>
        <.stat label="Mono" mono>default_58efe7505741</.stat>
        <.stat label="Negative" tone={:negative}>3 failed</.stat>
        <.stat label="Identifier"><.ident value="default_58efe7505741" /></.stat>
        <.stat label="Changing"><.live_value id="kit-live" value={length(@samples)} /></.stat>
        <.stat label="Sparkline"><.sparkline samples={@samples} /></.stat>
      </dl>
      <div class="mt-4 grid gap-3 max-w-md">
        <.meter value={3} max={10} label="3 of 10" />
        <.meter value={8} max={10} tone={:warning} label="8 of 10" />
        <.meter value={10} max={10} tone={:negative} label="10 of 10" />
        <.strip counts={[{:healthy, 6}, {:suspended, 1}, {:failed, 1}]} />
      </div>
    </.section>

    <.section testid="kit-statements">
      <:title>Notices, empty states, skeletons, code</:title>
      <div class="grid gap-4">
        <.notice>An informational note.</.notice>
        <.notice kind={:error}>An error, stated with its fix.</.notice>
        <.empty_state icon="hero-clock">
          A schedule starts a relay from a factory on a cron expression.
          <:action><.button size="sm">New schedule</.button></:action>
        </.empty_state>
        <.skeleton rows={3} />
        <.code_block>
          {~s({"payload": "a long line that wraps rather than scrolling sideways, as every payload, schema and token does in the console"}\n:ok)}
        </.code_block>
        <p>
          A <.term key="runner" /> serves <.term key="factory">factories</.term>; press
          <.kbd>?</.kbd>
          for help.
        </p>
      </div>
    </.section>

    <.section testid="kit-overlays">
      <:title>Overlays</:title>
      <div class="flex flex-wrap gap-3">
        <.button variant="secondary" phx-click="kit_drawer" data-testid="kit-open-drawer">
          Open drawer
        </.button>
        <.button variant="secondary" phx-click="kit_dialog" data-testid="kit-open-dialog">
          Open dialog
        </.button>
        <.button
          variant="secondary"
          phx-click="kit_flash"
          phx-value-kind="info"
          data-testid="kit-toast-info"
        >
          Info toast
        </.button>
        <.button
          variant="secondary"
          phx-click="kit_flash"
          phx-value-kind="error"
          data-testid="kit-toast-error"
        >
          Error toast
        </.button>
        <.popover id="kit-popover" label="A popover" trigger_class="fui-btn fui-btn--secondary">
          <:trigger>Popover</:trigger>
          <p class="fui-menu-note">A note</p>
          <button type="button" class="fui-menu-item" data-fui-pop-item>An item</button>
          <hr class="fui-menu-sep" />
          <button type="button" class="fui-menu-item fui-menu-item--danger" data-fui-pop-item>
            A danger item
          </button>
        </.popover>
        <.tooltip id="kit-tip" text="A hint for the control beside it.">
          <.button variant="ghost" aria-describedby="kit-tip">Tooltip</.button>
        </.tooltip>
      </div>
    </.section>

    <.section testid="kit-flows">
      <:title>Steps and tabs</:title>
      <.steps steps={["Factory", "Details", "Review"]} current={1}>
        <p>The current step's body.</p>
        <:foot>
          <.button variant="ghost">Back</.button>
          <.button>Next</.button>
        </:foot>
      </.steps>
      <div class="mt-6">
        <.tabs items={[
          %{label: "Live", path: "/dev/kit", current?: true},
          %{label: "Listen", path: "/dev/kit"},
          %{label: "State", path: "/dev/kit"}
        ]} />
      </div>
    </.section>

    <.drawer :if={@drawer?} id="kit-drawer" eyebrow="Relay" title="orders" on_close="kit_drawer">
      <p class="fui-sentence">A drawer opens beside the content and becomes a sheet on a phone.</p>
      <:actions><.button variant="secondary" phx-click="kit_drawer">Close</.button></:actions>
    </.drawer>

    <.confirm_dialog
      :if={@dialog?}
      title="Stop relay?"
      confirm_label="Stop"
      on_confirm="kit_dialog"
      on_cancel="kit_dialog"
      testid="kit-dialog"
    >
      Stop <.ident value="orders" full />? A confirmation's danger action is solid.
    </.confirm_dialog>
    """
  end
end
