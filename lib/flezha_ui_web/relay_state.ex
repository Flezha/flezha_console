defmodule FlezhaUiWeb.RelayState do
  @moduledoc """
  What a relay's state means and what happens to it next, and the one
  summary that explains it wherever a relay's condition is shown: on a
  problem's card, the relay screen and the relay inspector.

  A state is a health verdict, or `:unplaced` or `:coverage` for a healthy
  relay no node runs or whose partition group is broken. Who handles it and
  what happens next depend on how many runners serve its factory, which a
  caller reads and passes in; a fact nobody read is left out rather than
  guessed.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager

  @doc """
  A relay's state, from its registry row and its Overwatch's `suspended`
  flag: the registry's health, or suspended when the registry reads it
  healthy or unknown while its Overwatch reports it suspended at a committed
  boundary.
  """
  def of(nil, true), do: :suspended
  def of(nil, _suspended), do: :unknown

  def of(row, suspended) do
    case NodeManager.row_health(row) do
      health when health in [:healthy, :unknown] and suspended == true -> :suspended
      health -> health
    end
  end

  @doc """
  Why a relay whose factory `serving` runners serve cannot be called, or nil:
  with no runner, nobody can answer a call before its deadline. `serving` is
  nil while unread, which refuses nothing.
  """
  def unservable(0, factory),
    do: "Nobody can answer a call until a runner serves factory #{factory}."

  def unservable(_serving, _factory), do: nil

  # What happens to a message sent to a relay no runner serves: the
  # controller, not this note, decides.
  defp send_note(:suspended, 0, factory),
    do: "No runner serves #{factory} yet; the message is kept until one connects."

  defp send_note(_state, 0, factory),
    do:
      "No runner serves #{factory}; the controller keeps the message only if this relay journals its input."

  defp send_note(_state, _serving, _factory), do: nil

  @doc """
  What the talk controls say about a relay in `state` no runner serves: what
  a send does, then why Call is off. Nil when a runner serves it or nobody
  read the runners.
  """
  def no_runner_note(state, serving, factory) do
    with note when is_binary(note) <- send_note(state, serving, factory),
         do: "#{note} Call is off. #{unservable(serving, factory)}"
  end

  # The states whose handler depends on whether a runner serves the factory.
  @runner_bound [:suspended, :unbound, :failed, :recovering]

  @doc """
  The relay states whose handler depends on whether a runner serves the
  relay's factory: a caller reads the runners only when one of these is open.
  """
  def runner_bound_states, do: @runner_bound

  @doc "A state in lower-case words, as a sentence names it."
  def word(state), do: String.downcase(Words.text(:relay_state, state))

  # The controller's diagnosis outranks a count of runners: runners that
  # serve the factory but cannot take the relay wake nothing.
  @unplaceable ~w(diagnose.no_runner diagnose.runner_mismatch)

  @doc """
  Who acts next on a relay in `state` whose factory `serving` runners serve:
  `:nobody`, `:flezha` or `:you`, or nil when a suspended relay's runners were
  not read. A `diagnose.no_runner` or `diagnose.runner_mismatch` finding in
  `diagnosis` makes it `:you`, whatever the count says.
  """
  def handled_by(state, serving, diagnosis \\ nil) do
    if unplaceable?(diagnosis), do: :you, else: handler(state, serving)
  end

  defp handler(:healthy, _serving), do: :nobody
  defp handler(state, 0) when state in @runner_bound, do: :you
  defp handler(:suspended, nil), do: nil
  defp handler(:suspended, _serving), do: :nobody
  defp handler(state, _serving) when state in [:halted, :coverage], do: :you
  defp handler(_state, _serving), do: :flezha

  defp unplaceable?(%{findings: findings}), do: Enum.any?(findings, &(&1.code in @unplaceable))
  defp unplaceable?(_diagnosis), do: false

  @doc """
  A relay's condition facts, as `FlezhaUiWeb.CoreComponents.condition/1`
  takes them. A fact nobody read is left out: `runner` is `:unread` and
  `serving` nil then, and nothing then claims the relay will wake.
  """
  def condition_facts(state, opts \\ []) do
    factory = opts[:factory]
    serving = opts[:serving]
    handler = handled_by(state, serving, opts[:diagnosis])

    {cause, impact} = meaning(state)

    %{
      state: state_said(state),
      cause: cause,
      impact: impact,
      runner: runner_words(Keyword.get(opts, :runner, :unread), serving, factory),
      handled: handler && handler_said(handler),
      next: next_step(state, handler, factory, opts[:diagnosis])
    }
  end

  @doc "Who handles a condition, as its Handled by row shows it."
  def handler_said(handler),
    do: Map.put(Words.say(:handled_by, handler), :term, "handled by")

  # What put a relay in each state, and what that means for its traffic.
  @meaning %{
    healthy: {"Runs as declared", nil},
    suspended:
      {"Stopped at a committed boundary on purpose",
       "Processes nothing until it wakes; its inputs are kept"},
    unbound: {"No runner is bound", "Processes nothing until it is bound"},
    recovering: {"Its runner left; inside its grace", "Processes nothing until it is rebound"},
    failed: {"Its runner is gone past its grace", "Processes nothing until it is rebound"},
    degraded: {"Runs, but not as declared", "Its output may differ from its declaration"},
    halted: {"A fault the system cannot fix by itself", "Processes no input"},
    unknown: {"Not observed yet", "Not known yet"},
    unplaced: {"No live node runs it", "Processes nothing until a node runs it"},
    coverage:
      {"Its partition group's coverage is broken", "Traffic for uncovered key groups is lost"}
  }

  defp meaning(state),
    do: Map.get(@meaning, state, {"The Convergence Loop reports it #{word(state)}", nil})

  defp next_step(state, handler, factory, diagnosis) do
    if unplaceable?(diagnosis),
      do: "Start a runner that can take it",
      else: next_step(state, handler, factory)
  end

  defp next_step(state, :you, factory) when state in @runner_bound,
    do: "Start a runner that serves #{factory || "its factory"}"

  defp next_step(:suspended, :nobody, _factory), do: "Wakes on the next message or its timer"
  defp next_step(:unbound, :flezha, _factory), do: "Bound to a runner by Flezha"
  defp next_step(:recovering, :flezha, _factory), do: "Rebound by Flezha within its grace"
  defp next_step(:failed, :flezha, _factory), do: "Rebound to another runner by Flezha"
  defp next_step(:degraded, _handler, _factory), do: "Repaired in place by Flezha"

  defp next_step(:halted, _handler, _factory),
    do: "Fix the cause; Flezha retries its bind with a growing delay"

  defp next_step(:unknown, _handler, _factory), do: "Checked on the next tick"
  defp next_step(:unplaced, _handler, _factory), do: "Placed by Flezha"
  defp next_step(:coverage, _handler, _factory), do: "Fix the group's key ranges"
  defp next_step(_state, _handler, _factory), do: nil

  defp runner_words(runner, serving, factory) do
    bound =
      case runner do
        :unread -> nil
        nil -> "None bound"
        runner -> "#{runner} bound"
      end

    can_run = serving && "#{serving} can run it" <> ((factory && " (#{factory})") || "")

    case Enum.reject([bound, can_run], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  @doc """
  A relay's condition as labelled rows, in one order everywhere it is
  explained: its `condition_facts/2` and — once asked — the diagnosis.
  """
  attr :state, :atom, required: true
  attr :factory, :string, default: nil
  attr :runner, :any, default: :unread, doc: "the bound runner, nil for none, :unread"
  attr :serving, :integer, default: nil, doc: "how many runners serve the factory, nil unread"
  attr :diagnosis, :map, default: nil
  attr :error, :any, default: nil
  attr :testid, :string, default: "relay-state"
  attr :diagnosis_testid, :string, default: "diagnosis"

  def summary(assigns) do
    assigns =
      assign(assigns,
        facts:
          condition_facts(assigns.state,
            factory: assigns.factory,
            runner: assigns.runner,
            serving: assigns.serving,
            diagnosis: assigns.diagnosis
          )
      )

    ~H"""
    <.condition facts={@facts} testid={@testid} state={@state}>
      <:row :if={@diagnosis || @error} key="diagnosis" label="Diagnosis">
        <.diagnosis diagnosis={@diagnosis} error={@error} testid={@diagnosis_testid} />
      </:row>
    </.condition>
    """
  end

  # A state's words, tone and shape, with the glossary key of a health
  # verdict the glossary defines.
  defp state_said(state) do
    key = to_string(state)
    defined? = state in NodeManager.health_verdicts() and FlezhaUiWeb.Glossary.term(key) != nil
    Map.put(Words.say(:relay_state, state), :term, if(defined?, do: key))
  end

  @doc """
  What the controller answered to Diagnose: its verdict in words and each
  finding, or why it could not be asked. One rendering for the relay screen,
  the relay inspector and a problem's inline answer.
  """
  attr :diagnosis, :map, default: nil
  attr :error, :any, default: nil
  attr :testid, :string, default: "diagnosis"

  def diagnosis(assigns) do
    ~H"""
    <div data-testid={@testid} class="space-y-3">
      <div :if={@error} data-testid="diagnose-error">
        <.runtime_error error={@error} action="the diagnosis" />
      </div>
      <p :if={@diagnosis}>
        <.state_badge kind={:diagnosis} value={@diagnosis.verdict} testid="diagnose-verdict" />
      </p>
      <p :if={@diagnosis && @diagnosis.findings == []}>The controller found nothing to report.</p>
      <ol :if={@diagnosis && @diagnosis.findings != []} class="space-y-2">
        <li
          :for={finding <- @diagnosis.findings}
          data-testid={"diagnose-finding-#{finding.code}"}
        >
          <.runtime_error error={finding} kind={if finding.level == :note, do: :info, else: :error} />
        </li>
      </ol>
    </div>
    """
  end
end
