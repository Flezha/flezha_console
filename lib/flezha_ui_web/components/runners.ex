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
        <div class="table-scroll">
          <table data-testid={"runners-#{@namespace}"} class="flz-table">
            <thead>
              <tr>
                <th>Runner</th>
                <th>PID</th>
                <th :if={@factories?}>Serves</th>
                <th :if={@can_drop}><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={runner <- @runners} data-testid={"runner-#{runner.id}"}>
                <td class="text-th-primary flz-num text-xs">{runner.id}</td>
                <td data-testid={"os-pid-#{runner.id}"} class="flz-num text-xs">
                  {runner[:pid] || "—"}
                </td>
                <td :if={@factories?} class="text-xs">
                  {if runner[:factories] in [nil, []],
                    do: "no factories registered",
                    else: Enum.join(runner.factories, ", ")}
                </td>
                <td :if={@can_drop} class="text-right">
                  <button
                    phx-click="drop_runner"
                    phx-value-namespace={@namespace}
                    phx-value-runner={runner.id}
                    phx-value-pid={runner[:pid]}
                    data-testid={"drop-runner-#{runner.id}"}
                    class="flz-button flz-button--sm flz-button--ghost"
                  >
                    Drop
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>

      <div :if={@marks != []} data-testid={"runner-marks-#{@namespace}"}>
        <p class="flz-label mb-2">Dropped processes</p>
        <div class="table-scroll">
          <table class="flz-table">
            <thead>
              <tr>
                <th>Runner</th>
                <th>PID</th>
                <th>Node</th>
                <th>Dropped</th>
                <th>By</th>
                <th :if={@can_readmit}><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={mark <- @marks} data-testid={"runner-mark-#{mark.stable_id}"}>
                <td class="flz-num text-xs">
                  <span class="flz-badge flz-badge--negative mr-2">dropped</span>
                  {mark.stable_id}
                </td>
                <td class="flz-num text-xs">{mark[:pid] || "—"}</td>
                <td class="flz-num text-xs">{mark[:node] || "—"}</td>
                <td class="flz-num text-xs">{Format.unix_time(mark[:dropped_at], :second)}</td>
                <td class="flz-num text-xs">{mark[:dropped_by] || "—"}</td>
                <td :if={@can_readmit} class="text-right">
                  <button
                    phx-click="readmit_runner"
                    phx-value-namespace={@namespace}
                    phx-value-stable_id={mark.stable_id}
                    data-testid={"readmit-runner-#{mark.stable_id}"}
                    class="flz-button flz-button--sm flz-button--ghost"
                  >
                    Readmit
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
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
      Drop <.mono>{@drop.runner}</.mono>{if @drop.pid, do: " (pid #{@drop.pid})"}?
      The controller closes its session and moves its relays, and refuses this same
      process until a different one connects.
    </.confirm_dialog>

    <.confirm_dialog
      :if={@readmit}
      title="Readmit runner?"
      confirm_label="Readmit"
      variant="accent"
      on_confirm="confirm_readmit_runner"
      on_cancel="cancel_readmit_runner"
      values={%{"namespace" => @readmit.namespace, "stable_id" => @readmit.stable_id}}
      testid="readmit-runner-modal"
      cancel_testid="readmit-runner-cancel"
      confirm_testid="readmit-runner-confirm"
    >
      Lift the drop on <.mono>{@readmit.stable_id}</.mono>? The same process is admitted
      on its next retry.
    </.confirm_dialog>
    """
  end
end
