defmodule FlezhaUiWeb.Words do
  @moduledoc """
  The controller's values, said in words with a tone.

  Every state the console shows — a relay's health, a posture, a phase, a
  schedule, a quota — passes through `say/2`, which answers
  `%{text:, tone:}`: what to print, and `:positive`, `:warning`, `:negative`
  or `:neutral` for how to paint it. Health also carries a `:shape`, because
  state is never told by colour alone.

  One table for the whole console, so a value reads the same on every screen
  and no screen keeps a label map of its own. A value the table does not know
  is said in words too — humanised, never as an atom.
  """

  @type tone :: :positive | :warning | :negative | :neutral
  @type said :: %{
          required(:text) => String.t(),
          required(:tone) => tone(),
          optional(:shape) => String.t()
        }

  # Health, in the Convergence Loop's rank order, with the shape that tells
  # each apart without colour.
  @health %{
    healthy: {"Healthy", :positive, "dot"},
    unknown: {"Unknown", :neutral, "ring"},
    suspended: {"Suspended", :warning, "bars"},
    degraded: {"Degraded", :warning, "triangle"},
    recovering: {"Recovering", :warning, "half"},
    unbound: {"Unbound", :warning, "diamond"},
    failed: {"Failed", :negative, "cross"},
    parked: {"Parked", :negative, "square"}
  }

  @table %{
    authz_posture: %{
      open: {"Open — every call is allowed, whoever makes it", :warning},
      bootstrap_pending: {"Enforced but unclaimed — every operator verb is refused", :negative},
      enforced: {"Enforced — calls are checked against the caller's role", :positive}
    },
    durability_posture: %{
      local_only: {"Durable state has one copy, on the node that wrote it", :neutral},
      remote_tier: {"Durable state is shipped to a remote tier", :positive}
    },
    readiness: %{
      ready: {"Ready", :positive},
      booting: {"Booting", :warning},
      recovering: {"Recovering its hubs", :warning}
    },
    shutdown_phase: %{
      nil => {"Not stopping", :neutral},
      quiesce: {"Quiescing", :warning},
      drain: {"Draining", :warning},
      finalise: {"Finalising", :warning}
    },
    signal_handler: %{
      ok: {"Installed", :positive},
      degraded: {"Degraded", :warning},
      unknown: {"Unknown", :neutral}
    },
    hub_recovery: %{
      normal: {"Serving", :positive},
      recovering: {"Recovering", :warning},
      not_hosted: {"No hub on this node", :neutral},
      unreachable: {"Could not be reached", :neutral},
      unavailable: {"Unavailable", :neutral},
      unknown: {"Unknown", :neutral}
    },
    schedule: %{
      true => {"Active", :positive},
      false => {"Inactive", :neutral}
    },
    namespace_state: %{
      {true, true} => {"Declared and running", :positive},
      {true, false} => {"Declared, no hub running", :warning},
      {false, true} => {"Running, undeclared", :neutral},
      {false, false} => {"Not running", :neutral}
    },
    quota: %{
      breached: {"At its limit", :negative},
      within: {"Within its limit", :positive},
      unset: {"No limit applies", :neutral}
    },
    token_status: %{
      active: {"Active", :positive},
      revoked: {"Revoked", :neutral},
      expired: {"Expired", :neutral}
    },
    diagnosis: %{
      ok: {"Nothing wrong", :positive},
      warning: {"Worth a look", :warning},
      problem: {"A problem", :negative}
    },
    finding: %{
      note: {"Note", :neutral},
      warning: {"Warning", :warning},
      problem: {"Problem", :negative}
    },
    call_outcome: %{
      nil => {"Waiting", :neutral},
      answered: {"Answered", :positive},
      timed_out: {"Timed out", :warning},
      refused: {"Refused", :negative},
      not_heard: {"Outcome not heard", :warning}
    },
    call_source: %{
      "ui" => {"UI", :neutral},
      "cli" => {"CLI", :neutral},
      "sdk" => {"SDK", :neutral},
      "http" => {"HTTP", :neutral},
      "mcp" => {"MCP", :neutral},
      "plugin" => {"Plugin", :neutral},
      "relay" => {"Relay", :neutral},
      "internal" => {"Internal", :neutral}
    },
    input_type: %{
      "1" => {"Binary", :neutral},
      "2" => {"Text", :neutral},
      "3" => {"Custom", :neutral}
    },
    enabled: %{
      true => {"On", :positive},
      false => {"Off", :neutral}
    },
    boolean: %{
      true => {"Yes", :neutral},
      false => {"No", :neutral}
    },
    run: %{
      flow: {"flow", :neutral},
      steps: {"steps", :neutral}
    },
    completion: %{
      completed: {"Completed", :positive},
      failed: {"Failed", :negative},
      cancelled: {"Cancelled", :neutral}
    }
  }

  @doc """
  What `value` of `kind` says, as `%{text:, tone:}`.

      iex> FlezhaUiWeb.Words.say(:readiness, :ready)
      %{text: "Ready", tone: :positive}
      iex> FlezhaUiWeb.Words.say(:health, nil).text
      "Unknown"
  """
  @spec say(atom(), term()) :: said()
  def say(:health, value) do
    {text, tone, shape} = Map.get(@health, health(value), @health.unknown)
    %{text: text, tone: tone, shape: shape}
  end

  def say(kind, value) do
    case @table |> Map.fetch!(kind) |> lookup(value) do
      {text, tone} -> %{text: text, tone: tone}
      nil -> %{text: humanize(value), tone: :neutral}
    end
  end

  @doc "The words alone."
  def text(kind, value), do: say(kind, value).text

  @doc "The tone alone."
  def tone(kind, value), do: say(kind, value).tone

  @doc "Every health verdict, in rank order: what a health filter offers."
  def health_verdicts, do: FlezhaUi.Service.NodeManager.health_verdicts()

  @doc """
  The shape a tone is drawn with beside its words, so a tone is never told by
  colour alone.
  """
  def shape(:positive), do: "dot"
  def shape(:warning), do: "triangle"
  def shape(:negative), do: "cross"
  def shape(_neutral), do: "ring"

  @doc """
  The worst of `tones`: negative over warning over positive over neutral.
  What a strip, a count or a header paints a mixed set in.
  """
  def worst(tones) do
    Enum.find([:negative, :warning, :positive], :neutral, &(&1 in tones))
  end

  # A string value and an atom value name the same state: the controller
  # answers atoms, a URL or a form answers strings.
  defp lookup(table, value) do
    case Map.fetch(table, value) do
      {:ok, said} -> said
      :error when is_binary(value) -> Map.get(table, safe_atom(value))
      :error -> if is_atom(value) and not is_boolean(value), do: Map.get(table, to_string(value))
    end
  end

  defp health(value) when is_binary(value), do: safe_atom(value)
  defp health(value), do: value

  defp safe_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  @doc """
  A value no table names, in words: `:not_hosted` reads "Not hosted", a module
  reads by its last segment, and anything else as its own text.
  """
  def humanize(nil), do: "—"
  def humanize(value) when is_boolean(value), do: if(value, do: "Yes", else: "No")

  def humanize(value) when is_atom(value) do
    case Atom.to_string(value) do
      "Elixir." <> module -> module |> String.split(".") |> List.last()
      text -> text |> String.replace("_", " ") |> String.capitalize()
    end
  end

  def humanize(value) when is_binary(value), do: value
  def humanize(value) when is_number(value), do: to_string(value)
  def humanize(value), do: inspect(value)

  @doc """
  `count` of `noun`, pluralised by appending "s" unless `plural` says otherwise.

      iex> FlezhaUiWeb.Words.count(1, "relay")
      "1 relay"
      iex> FlezhaUiWeb.Words.count(3, "entry", "entries")
      "3 entries"
  """
  def count(count, noun, plural \\ nil)
  def count(1, noun, _plural), do: "1 #{noun}"
  def count(count, noun, plural), do: "#{count} #{plural || noun <> "s"}"

  @doc "Items joined as a sentence: \"a\", \"a and b\", \"a, b and c\"."
  def join([]), do: ""
  def join([one]), do: one
  def join(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)
end
