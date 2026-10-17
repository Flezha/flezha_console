defmodule FlezhaUiWeb.RelayState do
  @moduledoc """
  What a relay's state means and what happens to it next, and the one
  summary that explains it wherever a relay's condition is shown: on a
  problem's card, the relay screen and the relay inspector.

  A state is a health verdict, or `:unplaced` or `:coverage` for a healthy
  relay no node runs or whose partition group is broken. Whether a relay can
  wake depends on how many runners serve its factory, which a caller reads
  and passes in; a fact nobody read is left out rather than guessed.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager

  @doc """
  A relay's state, from its registry row and its Overwatch's `suspended` flag: the registry's health, or suspended when
  the registry reads it healthy or unknown while its Overwatch reports it
  suspended at a committed boundary.
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
  Why nothing can be sent to a relay whose factory `serving` runners serve,
  or nil: a relay no runner serves cannot act on a message, which would only
  wait. `serving` is nil while unread, which refuses nothing.
  """
  def unservable(0, factory),
    do:
      "No runner serves factory #{factory}, so a message would only wait. Start a runner that serves it first."

  def unservable(_serving, _factory), do: nil

  @doc """
  The relay states whose next step depends on whether a runner serves the
  relay's factory: a caller reads the runners only when one of these is open.
  """
  def runner_bound_states, do: [:suspended, :unbound, :failed, :recovering]

  @doc "A state in lower-case words, as a sentence names it."
  def word(state), do: String.downcase(Words.text(:relay_state, state))

  @doc """
  Why a relay is in `state`, saying only what the state means — never a fact
  the read that found it did not hold, such as whether a runner serves it.
  """
  def why(:suspended),
    do: "It stopped at a committed boundary on purpose; a suspension is planned, not a fault."

  def why(:unbound), do: "No runner is bound to it."

  def why(:degraded),
    do: "The Convergence Loop classifies it degraded: it runs, but not as declared."

  def why(:recovering),
    do: "Its runner went away or it lost its binding, and it is still inside its grace."

  def why(:failed), do: "Its runner is gone past its grace, so it is not running."

  def why(:parked),
    do: "A fault stopped it that nothing in the system owns, so it processes no input."

  def why(:unknown), do: "The Convergence Loop has not observed it yet."
  def why(:unplaced), do: "The registry holds it, but no live cluster node runs it."
  def why(:healthy), do: "The Convergence Loop finds it running as declared."
  def why(state), do: "The Convergence Loop reports it #{word(state)}."

  @doc """
  What happens to a relay in `state` next, given how many runners serve its
  `factory` (`serving`, nil when not read). Nil when there is nothing to say,
  or when the answer depends on runners nobody read.
  """
  def next_step(:suspended, nil, _factory), do: nil

  def next_step(:suspended, 0, factory),
    do: "Messages are kept, but it cannot run until #{a_runner_for(factory)} connects."

  def next_step(:suspended, _serving, _factory), do: "The next message wakes it on a runner."

  def next_step(:parked, _serving, _factory),
    do: "It stays stopped until someone fixes it; the Convergence Loop does not touch it."

  def next_step(state, 0, factory) when state in [:unbound, :failed, :recovering],
    do: "It waits until #{a_runner_for(factory)} connects."

  def next_step(state, _serving, _factory) when state in [:unbound, :failed],
    do: "The Convergence Loop is binding it to a runner."

  def next_step(:recovering, _serving, _factory),
    do: "The Convergence Loop is rebinding it within its grace."

  def next_step(:degraded, _serving, _factory),
    do: "The Convergence Loop is repairing it in place."

  def next_step(_state, _serving, _factory), do: nil

  defp a_runner_for(nil), do: "a runner for its factory"
  defp a_runner_for(factory), do: "a runner for #{factory}"

  @doc """
  A relay's condition as labelled rows, in one order everywhere it is
  explained: its state with the glossary's meaning, why, the runner bound to
  it, who can run it, what happens next and — once asked — the diagnosis.

  A fact the caller did not read is left out rather than guessed: `runner`
  is `:unread` and `serving` nil when nobody read them, and what happens next
  then never claims the relay will wake.
  """
  attr :state, :atom, required: true
  attr :why, :string, default: nil, doc: "defaults to what the state means"
  attr :factory, :string, default: nil
  attr :runner, :any, default: :unread, doc: "the bound runner, nil for none, :unread"
  attr :serving, :integer, default: nil, doc: "how many runners serve the factory, nil unread"
  attr :diagnosis, :map, default: nil
  attr :error, :any, default: nil
  attr :testid, :string, default: "relay-state"
  attr :why_testid, :string, default: nil
  attr :diagnosis_testid, :string, default: "diagnosis"

  def summary(assigns) do
    said = state_said(assigns.state)

    assigns =
      assign(assigns,
        said: said,
        why: assigns.why || why(assigns.state),
        next: next_or_refused(assigns)
      )

    ~H"""
    <dl class="fui-state-summary" data-testid={@testid} data-state={@state}>
      <div data-testid={"#{@testid}-state"}>
        <dt>State</dt>
        <dd>
          <span
            class={"fui-shape fui-tone-#{@said.tone}"}
            data-shape={@said.shape}
            aria-hidden="true"
          >
          </span>
          <.term :if={@said.term} key={@said.term} id={"#{@testid}-term"}>{@said.text}</.term>
          <span :if={!@said.term}>{@said.text}</span>
        </dd>
      </div>
      <div data-testid={@why_testid || "#{@testid}-why"}>
        <dt>Why</dt>
        <dd>{@why}</dd>
      </div>
      <div :if={@runner != :unread} data-testid={"#{@testid}-runner"}>
        <dt>Runner</dt>
        <dd class={@runner && "fui-ident"}>{@runner || "None bound"}</dd>
      </div>
      <div :if={@serving} data-testid={"#{@testid}-serving"}>
        <dt>Who can run it</dt>
        <dd>{serving_words(@serving, @factory)}</dd>
      </div>
      <div :if={@next} data-testid={"#{@testid}-next"}>
        <dt>What happens next</dt>
        <dd>{@next}</dd>
      </div>
      <div :if={@diagnosis || @error} data-testid={"#{@testid}-diagnosis"}>
        <dt>Diagnosis</dt>
        <dd><.diagnosis diagnosis={@diagnosis} error={@error} testid={@diagnosis_testid} /></dd>
      </div>
    </dl>
    """
  end

  # The controller's diagnosis outranks a count of runners: runners that
  # serve the factory but cannot take the relay wake nothing.
  @unplaceable ~w(diagnose.no_runner diagnose.runner_mismatch)

  defp next_or_refused(%{diagnosis: %{findings: findings}} = assigns) do
    if Enum.any?(findings, &(&1.code in @unplaceable)),
      do: "It cannot run until a runner that can take it connects.",
      else: next_step(assigns.state, assigns.serving, assigns.factory)
  end

  defp next_or_refused(assigns), do: next_step(assigns.state, assigns.serving, assigns.factory)

  # A state's words, tone and shape, with the glossary key of a health
  # verdict the glossary defines.
  defp state_said(state) do
    key = to_string(state)
    defined? = state in NodeManager.health_verdicts() and FlezhaUiWeb.Glossary.term(key) != nil
    Map.put(Words.say(:relay_state, state), :term, if(defined?, do: key))
  end

  defp serving_words(0, factory), do: "No runner serves #{factory_words(factory)}"

  defp serving_words(count, factory),
    do:
      "#{Words.count(count, "runner")} #{if count == 1, do: "serves", else: "serve"} #{factory_words(factory)}"

  defp factory_words(nil), do: "its factory"
  defp factory_words(factory), do: "factory #{factory}"

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
