defmodule FlezhaConsoleWeb.LogLines do
  @moduledoc """
  Log records as an operator reads them.

  A kind the console can say in words has a `sentence/2` clause; any other is
  listed by the columns its declaration names, each value through `cell/2`.
  So a kind the controller adds later is listed with no change here, and a
  richer reading of it is one more clause.

  A sentence is a list of parts: text, `{:relay, ns, id}` and `{:factory, ns,
  id}` that link, `{:said, kind, value}` said in its tone through
  `FlezhaConsoleWeb.Words`, and `{:error, text}`. A field a record lacks is
  left out, never shown as a placeholder.
  """

  use FlezhaConsoleWeb, :html

  @doc """
  `record` of the kind `kind` as `%{parts:, tone:}`, or `nil` for a kind with
  no sentence.
  """
  def sentence("relay_history", record) when is_map(record),
    do: %{parts: record |> history() |> merged(), tone: tone(record)}

  def sentence(_kind, _record), do: nil

  @doc "A sentence's parts as plain text."
  def text(%{parts: parts}), do: Enum.map_join(parts, &part_text/1)

  # Neighbouring text is one part, so no space is left alone in its own tag.
  defp merged([a, b | rest]) when is_binary(a) and is_binary(b), do: merged([a <> b | rest])
  defp merged([part | rest]), do: [part | merged(rest)]
  defp merged([]), do: []

  defp part_text({:relay, _ns, id}), do: id
  defp part_text({:factory, _ns, id}), do: id
  defp part_text({:said, kind, value}), do: Words.text(kind, value)
  defp part_text({:error, text}), do: text
  defp part_text(text) when is_binary(text), do: text

  @doc """
  A relay history record's tone: its outcome's for an `ended` one, negative
  for a start that failed, neutral otherwise.
  """
  def tone(%{"event" => "ended", "outcome" => outcome}), do: Words.tone(:run_outcome, outcome)
  def tone(%{"event" => "start_failed"}), do: :negative
  def tone(_record), do: :neutral

  @doc """
  Who or what started a relay history record's run, as a line of its own
  ("Spawned by ma_fan"), or `nil` when the record names no origin.
  """
  def origin_line(record) do
    case origin(record) do
      [", ", lead | who] -> %{parts: merged([Words.sentence_start(lead) | who]), tone: :neutral}
      [] -> nil
    end
  end

  @doc "What an outcome means, where its word alone does not say it."
  def outcome_note("undone"), do: "Its completed steps were compensated."
  def outcome_note(_outcome), do: nil

  defp history(%{"event" => "started"} = record) do
    [relay(record), " started"] ++ from(record) ++ origin(record)
  end

  defp history(%{"event" => "ended"} = record) do
    [relay(record), " finished"] ++
      outcome(record) ++
      if(record["halted"] == true, do: [", having halted first"], else: []) ++
      origin(record) ++ error(record, ". ")
  end

  defp history(%{"event" => "start_failed"} = record) do
    [relay(record), " could not start"] ++ from(record) ++ error(record, ": ")
  end

  defp history(record) do
    [relay(record), " ", worded(record["event"])]
  end

  defp relay(record), do: {:relay, record["namespace"], record["relay"]}

  defp from(%{"factory" => factory} = record) when factory not in [nil, ""],
    do: [" from ", {:factory, record["namespace"], factory}]

  defp from(_record), do: []

  defp outcome(%{"outcome" => outcome} = record) when outcome not in [nil, ""] do
    [": ", {:said, :run_outcome, outcome}] ++
      case record["duration_ms"] do
        ms when is_integer(ms) -> [" after " <> Format.took(ms)]
        _none -> []
      end
  end

  defp outcome(_record), do: []

  defp error(%{"error" => error}, lead) when is_binary(error) and error != "",
    do: [lead, {:error, error}]

  defp error(_record, _lead), do: []

  defp origin(%{"origin" => %{"kind" => kind} = origin} = record) do
    [", ", Words.text(:run_origin, kind)] ++ who(kind, origin, record["namespace"])
  end

  defp origin(_record), do: []

  defp who("operator", origin, _ns) do
    principal = present(origin["principal"]) || "an operator"

    case present(origin["source"]) do
      nil -> [" " <> principal]
      source -> [" #{principal} through the #{Words.text(:call_source, source)}"]
    end
  end

  defp who("schedule", origin, _ns), do: [" " <> (present(origin["schedule"]) || "unnamed")]

  defp who(kind, origin, ns) when kind in ["spawn", "call"] do
    case present(origin["parent_relay"]) do
      nil -> [" another relay"]
      parent -> [" ", {:relay, ns, parent}]
    end
  end

  defp who(_kind, _origin, _ns), do: []

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  @doc """
  A value a declared enum filter offers, in words: an outcome as the history
  says it, anything else humanised.
  """
  def choice("outcome", value), do: :run_outcome |> Words.text(value) |> Words.sentence_start()
  def choice(_field, value), do: value |> worded() |> Words.sentence_start()

  # A value the controller names in snake case, as words.
  defp worded(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp worded(value), do: value |> Words.humanize() |> Words.in_sentence()

  @doc """
  A declared column's value of `record`, as text: a dash for none, a map by
  its values, a list joined.
  """
  def cell(record, field), do: value_text(Map.get(record, field))

  defp value_text(value) when value in [nil, "", [], %{}], do: "—"
  defp value_text(value) when is_binary(value), do: value
  defp value_text(value) when is_boolean(value) or is_atom(value), do: Words.humanize(value)
  defp value_text(value) when is_number(value), do: to_string(value)

  defp value_text(value) when is_map(value) do
    value
    |> Enum.sort()
    |> Enum.map(fn {_key, inner} -> inner end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> value_text()
  end

  defp value_text(value) when is_list(value), do: Enum.map_join(value, " · ", &value_text/1)
  defp value_text(value), do: inspect(value)

  @doc """
  A record's wall-clock time in milliseconds, as its controller stamped it,
  or `nil`.
  """
  def time(%{"ts_us" => ts_us}) when is_integer(ts_us), do: div(ts_us, 1_000)
  def time(_record), do: nil

  @doc "A sentence, its relay and factory linked."
  attr :line, :map, required: true, doc: "what `sentence/2` answers"
  attr :testid, :string, default: nil

  def line(assigns) do
    ~H"""
    <%!-- One line: whitespace between the parts would show before their punctuation. --%>
    <span data-testid={@testid} data-tone={@line.tone} phx-no-format><%= for part <- @line.parts do %><.line_part part={part} /><% end %></span>
    """
  end

  defp line_part(%{part: {:relay, ns, id}} = assigns) when is_binary(ns) and is_binary(id) do
    assigns = assign(assigns, ns: ns, id: id)

    ~H"""
    <.link navigate={~p"/namespaces/#{@ns}/relays/#{@id}"} class="fcon-ident" phx-no-format>{@id}</.link>
    """
  end

  defp line_part(%{part: {:factory, ns, factory}} = assigns) when is_binary(factory) do
    query = Enum.reject([namespace: ns, factory: factory], fn {_key, value} -> is_nil(value) end)
    assigns = assign(assigns, query: query, factory: factory)

    ~H"""
    <.link navigate={~p"/logs/relay_history?#{@query}"} class="fcon-ident" phx-no-format>{@factory}</.link>
    """
  end

  defp line_part(%{part: {:said, kind, value}} = assigns) do
    assigns = assign(assigns, kind: kind, value: value)

    ~H"""
    <.said kind={@kind} value={@value} />
    """
  end

  defp line_part(%{part: {:error, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <code class="fcon-tone-negative" phx-no-format>{@text}</code>
    """
  end

  defp line_part(%{part: part} = assigns) do
    assigns = assign(assigns, :text, part_text(part))

    ~H"""
    <span phx-no-format>{@text}</span>
    """
  end
end
