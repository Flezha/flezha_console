defmodule FlezhaConsoleWeb.Runners do
  @moduledoc """
  A namespace's runners and the drop marks standing against its runner
  processes, as one table.

  The cluster screen and a namespace's detail page both list runners, and both
  offer the same Drop and Readmit; one table keeps the two lists and their
  actions from drifting. The events it sends are handled by
  `FlezhaConsoleWeb.Live.RunnerActions`.
  """

  use FlezhaConsoleWeb, :html

  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.ListingView

  # Runners are bounded in hundreds, so the table filters and sorts in memory.
  @view ListingView.declare(
          filters: [node: nil, late: nil],
          sorts: [late: "Late first", newest: "Newest connection"],
          defaults: %{"late" => "false"}
        )

  @doc """
  The rows `runner_table/1` lists, from the runners `NodeManager.runners/2`
  answers: each credited with the factories `factories_by_runner` names, and
  `same_set`, how many other runners serve exactly its factories. A fact the
  controller did not answer is `nil`.
  """
  def rows(runners, factories_by_runner \\ %{}) do
    rows =
      Enum.map(runners, fn runner ->
        id = NodeManager.identifier_id(runner)
        facts = if is_map(runner), do: runner, else: %{}

        %{
          id: id,
          node: facts[:node],
          connected_at: facts[:connected_at],
          silent_ms: facts[:silent_ms],
          late?: facts[:late?] == true,
          factories: Map.get(factories_by_runner, id, [])
        }
      end)

    sets = rows |> Enum.reject(&(&1.factories == [])) |> Enum.frequencies_by(& &1.factories)
    Enum.map(rows, &Map.put(&1, :same_set, Map.get(sets, &1.factories, 1) - 1))
  end

  @doc """
  The view of a runner table `params` ask for; with none, no filter and late
  runners first.
  """
  def view(params \\ %{}), do: ListingView.parse(@view, params)

  # `rows` as a whole view (`view/1`) filters and orders them.
  defp listed(rows, view) do
    query = view["q"] |> to_string() |> String.trim() |> String.downcase()

    rows
    |> Enum.filter(fn row ->
      matches_query?(row, query) and view["node"] in ["", to_string(row.node)] and
        (view["late"] != "true" or row.late?)
    end)
    |> Enum.sort_by(&sort_key(&1, view["sort"]))
  end

  defp matches_query?(_row, ""), do: true

  defp matches_query?(row, query),
    do: Enum.any?([row.id | row.factories], &String.contains?(String.downcase(&1), query))

  defp sort_key(row, "newest"), do: {-(row.connected_at || 0), row.id}

  defp sort_key(row, _late_first),
    do: {if(row.late?, do: 0, else: 1), -(row.silent_ms || 0), row.id}

  attr :namespace, :string, required: true
  attr :runners, :list, required: true, doc: "the rows `rows/3` builds"
  attr :marks, :list, default: []
  attr :factories?, :boolean, default: false, doc: "true to show what each runner serves"

  attr :view, :map,
    default: nil,
    doc: "this table's filter and order, from the host's `@runner_views`"

  attr :can_drop, :boolean, default: false
  attr :can_readmit, :boolean, default: false
  attr :error, :any, default: nil, doc: "the last drop or readmit refusal for this namespace"
  attr :paging, :map, default: nil, doc: "the host's `@paging`"
  slot :empty, required: true, doc: "what stands in when no runner is connected"

  def runner_table(assigns) do
    view = view(assigns.view)

    assigns =
      assign(assigns,
        view: view,
        listed: listed(assigns.runners, view),
        nodes:
          assigns.runners
          |> Enum.map(& &1.node)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort(),
        served: assigns.runners |> Enum.flat_map(& &1.factories) |> Enum.uniq() |> length(),
        late: Enum.count(assigns.runners, & &1.late?),
        now: System.system_time(:second),
        sorts: ListingView.sorts(@view)
      )

    ~H"""
    <div class="space-y-4">
      <.runtime_error error={@error} action="the runner action" />

      <%= if @runners == [] do %>
        {render_slot(@empty)}
      <% else %>
        <p class="fcon-figures" data-testid={"runners-summary-#{@namespace}"}>
          {length(@runners)} connected · {length(@nodes)} {if length(@nodes) == 1,
            do: "node",
            else: "nodes"}<span :if={@factories?}> · {@served} factories served</span>
          · <span class={@late > 0 && "fcon-tone-warning"}>{@late} late</span>
        </p>

        <form
          id={"runner-view-#{@namespace}"}
          phx-change="runner_view"
          class="flex flex-wrap items-end gap-3"
          data-testid={"runner-view-#{@namespace}"}
          onsubmit="return false"
        >
          <input type="hidden" name="namespace" value={@namespace} />
          <.input
            type="search"
            name="view[q]"
            id={"runner-q-#{@namespace}"}
            label="Filter"
            value={@view["q"]}
            placeholder={if @factories?, do: "Runner or factory", else: "Runner"}
            phx-debounce="300"
            compact
            data-testid={"runner-filter-#{@namespace}"}
          />
          <.combobox
            :if={length(@nodes) > 1}
            label="Node"
            id={"runner-node-#{@namespace}"}
            name="view[node]"
            value={@view["node"]}
            testid={"runner-node-#{@namespace}"}
            prompt="All"
            class="w-48"
          >
            <:option value="">All</:option>
            <:option :for={node <- @nodes} value={to_string(node)}>{node}</:option>
          </.combobox>
          <.combobox
            label="Sort"
            id={"runner-sort-#{@namespace}"}
            name="view[sort]"
            value={@view["sort"]}
            testid={"runner-sort-#{@namespace}"}
            class="w-48"
          >
            <:option :for={{value, label} <- @sorts} value={value}>{label}</:option>
          </.combobox>
          <.input
            type="checkbox"
            name="view[late]"
            id={"runner-late-#{@namespace}"}
            label="Late only"
            checked={@view["late"] == "true"}
            data-testid={"runner-late-#{@namespace}"}
          />
        </form>

        <p :if={@listed == []} class="fcon-figures" data-testid={"runners-none-match-#{@namespace}"}>
          No runner matches this filter.
        </p>

        <.grid
          :if={@listed != []}
          paging={@paging}
          id={"runners-#{@namespace}-grid"}
          rows={@listed}
          testid={"runners-#{@namespace}"}
          row_testid={&"runner-#{&1.id}"}
          row_tone={&(&1.late? && "warning")}
        >
          <:col :let={runner} label="Runner"><.ident value={runner.id} /></:col>
          <:col :let={runner} label="Node">
            <.ident value={runner.node || "—"} full testid={"runner-node-of-#{runner.id}"} />
          </:col>
          <:col :let={runner} label="Connected">
            <.moment at={runner.connected_at} now={@now} testid={"runner-connected-#{runner.id}"} />
          </:col>
          <:col :let={runner} label="Last contact" num>
            <span
              data-testid={"runner-contact-#{runner.id}"}
              data-late={runner.late? && "true"}
              class={runner.late? && "fcon-tone-warning"}
            >
              {if runner.silent_ms, do: Format.ago(runner.silent_ms), else: "—"}
            </span>
          </:col>
          <%!-- The controller counts no relays per runner, so the listing
                filtered to this runner is where they are counted. --%>
          <:col :let={runner} label="Relays" num>
            <.link
              navigate={~p"/namespaces/#{@namespace}/relays?#{[runner: runner.id]}"}
              data-testid={"runner-relays-#{runner.id}"}
            >
              List them
            </.link>
          </:col>
          <:col :let={runner} :if={@factories?} label="Serves">
            <.serves namespace={@namespace} runner={runner} />
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
                values={%{namespace: @namespace, runner: runner.id, where: where(runner)}}
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
        <h3 class="fcon-eyebrow">Dropped processes</h3>
        <.grid
          paging={@paging}
          id={"runner-marks-#{@namespace}-grid"}
          rows={@marks}
          row_testid={&"runner-mark-#{&1.stable_id}"}
          row_tone={fn _mark -> "negative" end}
        >
          <:col :let={mark} label="Runner">
            <span class="flex items-center gap-2">
              <span class="fcon-badge fcon-badge--negative">
                <span class="fcon-shape" data-shape="cross" aria-hidden="true"></span>Dropped
              </span>
              <.ident value={mark.stable_id} />
            </span>
          </:col>
          <:col :let={mark} label="OS pid" num>{mark[:pid] || "—"}</:col>
          <:col :let={mark} label="Node"><span class="fcon-ident">{mark[:node] || "—"}</span></:col>
          <:col :let={mark} label="Dropped" num>{Format.unix_time(mark[:dropped_at], :second)}</:col>
          <:col :let={mark} label="By">
            <span class="fcon-ident">{mark[:dropped_by] || "—"}</span>
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

  # Two factories, the rest behind a toggle that survives the refresh patch.
  attr :namespace, :string, required: true
  attr :runner, :map, required: true

  defp serves(assigns) do
    {shown, rest} = Enum.split(assigns.runner.factories, 2)
    rest_id = "serves-rest-#{assigns.namespace}-#{assigns.runner.id}"
    assigns = assign(assigns, shown: shown, rest: rest, rest_id: rest_id)

    ~H"""
    <span :if={@runner.factories == []} class="fcon-figures">no factories registered</span>
    <span :if={@runner.factories != []} class="flex flex-wrap items-center gap-1">
      <.chip :for={factory <- @shown} mono>{factory}</.chip>
      <span id={@rest_id} class="contents" style="display: none">
        <.chip :for={factory <- @rest} mono>{factory}</.chip>
      </span>
      <button
        :if={@rest != []}
        type="button"
        class="fcon-chip cursor-pointer"
        aria-controls={@rest_id}
        aria-expanded="false"
        phx-click={
          JS.toggle(to: "##{@rest_id}", display: "contents")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
        }
        data-testid={"serves-more-#{@runner.id}"}
      >
        +{length(@rest)} more
      </button>
    </span>
    <p :if={@runner.same_set > 0} class="fcon-muted text-xs" data-testid={"same-set-#{@runner.id}"}>
      same {length(@runner.factories)} as {@runner.same_set} other {if @runner.same_set == 1,
        do: "runner",
        else: "runners"}
    </p>
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
      Drop <.ident value={@drop.runner} full />{@drop.where}?
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

  # Where a runner is held and since when, for the drop confirmation to name it by.
  defp where(%{node: node, connected_at: connected_at}) do
    facts =
      Enum.filter(
        [
          node && "on #{node}",
          is_integer(connected_at) && "connected #{Format.relative(connected_at, :second)}"
        ],
        & &1
      )

    if facts == [], do: "", else: " (#{Enum.join(facts, ", ")})"
  end
end
