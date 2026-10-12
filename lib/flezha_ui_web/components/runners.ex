defmodule FlezhaUiWeb.Runners do
  @moduledoc """
  A namespace's runners and the drop marks standing against its runner
  processes, as one table.

  The cluster screen and a namespace's detail page both list runners, and both
  offer the same Drop and Readmit; one table keeps the two lists and their
  actions from drifting. The events it sends are handled by
  `FlezhaUiWeb.Live.RunnerActions`.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager

  @doc """
  The rows `runner_table/1` lists, from the runners `NodeManager.runners/2`
  answers, each credited with the factories `factories_by_runner` names.
  """
  def rows(runners, factories_by_runner \\ %{}) do
    Enum.map(runners, fn runner ->
      id = NodeManager.identifier_id(runner)
      %{id: id, pid: Map.get(runner, :pid), factories: Map.get(factories_by_runner, id, [])}
    end)
  end

  attr :namespace, :string, required: true
  attr :runners, :list, required: true, doc: "`[%{id:, pid:}]`, with `factories:` when shown"
  attr :marks, :list, default: []
  attr :factories?, :boolean, default: false, doc: "true to show what each runner serves"
  attr :can_drop, :boolean, default: false
  attr :can_readmit, :boolean, default: false
  attr :error, :any, default: nil, doc: "the last drop or readmit refusal for this namespace"
  slot :empty, required: true, doc: "what stands in when no runner is connected"

  def runner_table(assigns) do
    ~H"""
    <div class="space-y-4">
      <.runtime_error error={@error} action="the runner action" />

      <%= if @runners == [] do %>
        {render_slot(@empty)}
      <% else %>
        <.grid
          id={"runners-#{@namespace}-grid"}
          rows={@runners}
          testid={"runners-#{@namespace}"}
          row_testid={&"runner-#{&1.id}"}
        >
          <:col :let={runner} label="Runner"><.ident value={runner.id} /></:col>
          <:col :let={runner} label="OS pid" num>
            <span data-testid={"os-pid-#{runner.id}"}>{runner[:pid] || "—"}</span>
          </:col>
          <:col :let={runner} :if={@factories?} label="Serves">
            <span :if={runner[:factories] in [nil, []]} class="fui-figures">
              no factories registered
            </span>
            <span class="flex flex-wrap gap-1">
              <.chip :for={factory <- runner[:factories] || []} mono>{factory}</.chip>
            </span>
          </:col>
          <:menu :let={runner}>
            <.row_menu
              :if={@can_drop}
              id={"runner-menu-#{@namespace}-#{runner.id}"}
              label={"Actions for runner #{runner.id}"}
              testid={"runner-menu-#{runner.id}"}
            >
              <:item
                click="drop_runner"
                values={%{namespace: @namespace, runner: runner.id, pid: runner[:pid]}}
                testid={"drop-runner-#{runner.id}"}
                danger
              >
                Drop
              </:item>
            </.row_menu>
          </:menu>
        </.grid>
      <% end %>

      <div :if={@marks != []} data-testid={"runner-marks-#{@namespace}"} class="space-y-2">
        <h3 class="fui-eyebrow">Dropped processes</h3>
        <.grid
          id={"runner-marks-#{@namespace}-grid"}
          rows={@marks}
          row_testid={&"runner-mark-#{&1.stable_id}"}
          row_tone={fn _mark -> "negative" end}
        >
          <:col :let={mark} label="Runner">
            <span class="flex items-center gap-2">
              <span class="fui-badge fui-badge--negative">
                <span class="fui-shape" data-shape="cross" aria-hidden="true"></span>Dropped
              </span>
              <.ident value={mark.stable_id} />
            </span>
          </:col>
          <:col :let={mark} label="OS pid" num>{mark[:pid] || "—"}</:col>
          <:col :let={mark} label="Node"><span class="fui-ident">{mark[:node] || "—"}</span></:col>
          <:col :let={mark} label="Dropped" num>{Format.unix_time(mark[:dropped_at], :second)}</:col>
          <:col :let={mark} label="By">
            <span class="fui-ident">{mark[:dropped_by] || "—"}</span>
          </:col>
          <:menu :let={mark}>
            <.row_menu
              :if={@can_readmit}
              id={"mark-menu-#{@namespace}-#{mark.stable_id}"}
              label={"Actions for #{mark.stable_id}"}
              testid={"mark-menu-#{mark.stable_id}"}
            >
              <:item
                click="readmit_runner"
                values={%{namespace: @namespace, stable_id: mark.stable_id}}
                testid={"readmit-runner-#{mark.stable_id}"}
              >
                Readmit
              </:item>
            </.row_menu>
          </:menu>
        </.grid>
      </div>
    </div>
    """
  end

  @doc """
  The confirmations a runner table's actions open. Rendered once per screen,
  however many tables it holds.
  """
  attr :drop, :map, default: nil
  attr :readmit, :map, default: nil

  def runner_dialogs(assigns) do
    ~H"""
    <.confirm_dialog
      :if={@drop}
      title="Drop runner?"
      confirm_label="Drop"
      on_confirm="confirm_drop_runner"
      on_cancel="cancel_drop_runner"
      values={%{"namespace" => @drop.namespace, "runner" => @drop.runner}}
      testid="drop-runner-modal"
      cancel_testid="drop-runner-cancel"
      confirm_testid="drop-runner-confirm"
    >
      Drop <.ident value={@drop.runner} full />{if @drop.pid, do: " (pid #{@drop.pid})"}?
      The controller closes its session and moves its relays, and refuses this same
      process until a different one connects.
    </.confirm_dialog>

    <.confirm_dialog
      :if={@readmit}
      title="Readmit runner?"
      confirm_label="Readmit"
      variant="primary"
      on_confirm="confirm_readmit_runner"
      on_cancel="cancel_readmit_runner"
      values={%{"namespace" => @readmit.namespace, "stable_id" => @readmit.stable_id}}
      testid="readmit-runner-modal"
      cancel_testid="readmit-runner-cancel"
      confirm_testid="readmit-runner-confirm"
    >
      Lift the drop on <.ident value={@readmit.stable_id} full />? The same process is admitted
      on its next retry.
    </.confirm_dialog>
    """
  end
end
