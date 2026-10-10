defmodule FlezhaUi.CoverageLedgerTest do
  @moduledoc ~S"""
  Every control and every event in `lib/` is driven by some test.

  Read from `lib/` (`.ex` and `.heex`, docs and comments left out), tag by tag:

    * test ids: the literal value of each `data-testid`, `testid` or
      `<x>_testid` attribute. `{"relay-row-#{id}"}` counts by its literal
      prefix, written `relay-row-*`, as does a literal ending in `-`, which a
      component extends. A value with no leading literal, such as a
      component's own `{@testid}`, counts nothing: its call sites carry the
      literals.
    * events: each literal `handle_event/3` clause name and each name in an
      `@events ~w(...)` list a module dispatches through a guard.
    * bindings: the literal event of each `phx-*` event attribute, including
      what `JS.push/2` pushes, and of each `on_<x>` attribute a component
      turns into a `phx-click`. A binding is tied to the test id in its own
      tag: `data-testid` or `testid` for `phx-*`, `<x>_testid` for `on_<x>`.

  Read from `e2e/*.ts` and `test/**/*.exs`, this file aside and lines that
  refute a control or assert it absent left out, as names: each
  `data-testid=` or `data-testid^=` selector value, each `~w(...)` word and
  the leading literal of every string, up to its end or its first
  interpolation.

  A name equal to an exact id covers it. Any other name covers the longest
  prefix id it starts with, so `relay-row-relay_a` and `` `relay-row-${id}` ``
  both cover `relay-row-*`. An event is covered when a test names it in a
  `render_*` call, or when markup binds it to a test id a test acts on: a
  browser `click`, `fill`, `check`, `selectOption` or `press` on that id, a
  fixture helper that drives it, or an ExUnit `render_*` on its element.
  Naming a control is not driving it. Coverage is
  by name across the tree, not per screen.

  An exemption names an id (a prefix as `x-*`) or an event, with the reason it
  can never be driven.
  """

  use ExUnit.Case, async: true

  alias FlezhaUi.NamingGate

  # Fewer than these means a pattern stopped matching, and a ledger that
  # collects nothing passes everything.
  @ids_floor 350
  @events_floor 100
  @bindings_floor 100

  # {test id or event, reason}
  @exempt [
    {"close",
     "the palette's phx-click-away, fired by the browser outside the element: LiveViewTest " <>
       "cannot send it, and console-navigation.spec.ts clicks outside the palette and asserts it closed"}
  ]

  @own_file Path.relative_to_cwd(__ENV__.file)

  # A `{...}` expression: braces balanced, strings skipped whole.
  @expr ~S/(?(DEFINE)(?<x>\{(?:[^{}"]++|"(?:[^"\\]|\\.)*+"|(?&x))*+\}))/

  @event_attr ~r/^(?:phx-(?:click|click-away|capture-click|submit|change|blur|focus|keydown|keyup|window-[a-z]+|viewport-top|viewport-bottom|mounted|remove|connected|disconnected)|on_([a-z_]+))$/

  setup_all do
    %{ledger: ledger()}
  end

  test "every test id in lib is driven by a test", %{ledger: ledger} do
    open = exempted(ledger.uncovered_ids)

    assert open == [],
           "test ids no test names (#{length(open)}):\n" <> by_file(open)
  end

  test "every event in lib is driven by a test", %{ledger: ledger} do
    open = exempted(ledger.uncovered_events)

    assert open == [],
           "events no test drives (#{length(open)}):\n" <> by_file(open)
  end

  test "every event markup binds is handled", %{ledger: ledger} do
    open = exempted(ledger.unhandled)

    assert open == [],
           "bindings to an event no clause handles (#{length(open)}):\n" <> by_file(open)
  end

  test "every exemption gives its reason" do
    blank =
      for {name, reason} <- @exempt,
          not (is_binary(reason) and String.trim(reason) != ""),
          do: name

    assert blank == [], "exemptions without a reason: #{Enum.join(blank, ", ")}"
  end

  test "every exemption still excuses something", %{ledger: ledger} do
    open =
      Enum.map(ledger.uncovered_ids ++ ledger.uncovered_events ++ ledger.unhandled, &elem(&1, 0))

    stale = for {name, _reason} <- @exempt, name not in open, do: name

    assert stale == [], "exemptions that excuse nothing, delete them: #{Enum.join(stale, ", ")}"
  end

  test "the ledger reads lib and the tests", %{ledger: ledger} do
    assert ledger.ids >= @ids_floor
    assert ledger.events >= @events_floor
    assert ledger.bindings >= @bindings_floor
  end

  defp ledger do
    files = NamingGate.all_files()
    lib = for f <- files, lib_file?(f), do: {f, lib_source(f)}
    tests = for f <- files, test_file?(f), do: File.read!(f)

    tags = for {f, src} <- lib, attrs <- tag_attrs(src), do: {f, attrs}

    ids =
      for {f, attrs} <- tags,
          {name, value} <- attrs,
          testid_attr?(name),
          id = id_of(value),
          uniq: true,
          do: {id, f}

    bindings =
      for {f, attrs} <- tags,
          binding <- bindings(attrs),
          uniq: true,
          do: Tuple.insert_at(binding, 2, f)

    events = for {f, src} <- lib, name <- handled(src), uniq: true, do: {name, f}

    covered = covered_ids(MapSet.new(ids, &elem(&1, 0)), test_names(tests))

    driven = driven_events(tests)

    acted =
      covered_ids(MapSet.new(ids, &elem(&1, 0)), test_names(Enum.map(tests, &acting_lines/1)))

    bound = for {event, id, _f, _attr} <- bindings, id in acted, into: MapSet.new(), do: event
    handled = MapSet.new(events, &elem(&1, 0))

    %{
      ids: length(ids),
      events: length(events),
      bindings: length(bindings),
      uncovered_ids: Enum.reject(ids, &(elem(&1, 0) in covered)),
      uncovered_events: Enum.reject(events, &(elem(&1, 0) in driven or elem(&1, 0) in bound)),
      # `lv:` events are LiveView's own.
      unhandled:
        for(
          {event, _id, f, attr} <- bindings,
          event not in handled,
          not String.starts_with?(event, "lv:"),
          uniq: true,
          do: {event, f, ~s(#{attr}="#{event}")}
        )
    }
  end

  defp lib_file?(path),
    do: String.starts_with?(path, "lib/") and Path.extname(path) in ~w(.ex .heex)

  defp test_file?(path) do
    path != @own_file and
      ((Path.dirname(path) == "e2e" and Path.extname(path) == ".ts") or
         (String.starts_with?(path, "test/") and Path.extname(path) == ".exs"))
  end

  defp lib_source(path) do
    path
    |> File.read!()
    |> String.replace(
      ~r/@(?:module)?doc\s+(?:~[sS])?"""[\s\S]*?"""|@(?:module)?doc\s+"(?:[^"\\]|\\.)*"/,
      ""
    )
    |> String.replace(~r/<%!--[\s\S]*?--%>|<!--[\s\S]*?-->|^\s*#.*$/m, "")
  end

  defp tag_attrs(src) do
    tag =
      Regex.compile!(
        @expr <>
          ~S'<[.A-Za-z][\w.:-]*+(?<attrs>(?:\s++(?:(?&x)|[^\s=>{}"/]++(?:\s*+=\s*+(?:"[^"]*+"|(?&x)))?))*+)\s*+/?>'
      )

    attr =
      Regex.compile!(
        @expr <> ~S'(?&x)|(?<name>[^\s=>{}"/]++)(?:\s*+=\s*+(?<value>"[^"]*+"|(?&x)))?'
      )

    for [attrs] <- Regex.scan(tag, src, capture: ["attrs"]) do
      for [name, value] <- Regex.scan(attr, attrs, capture: ["name", "value"]),
          name != "",
          do: {name, value}
    end
  end

  defp testid_attr?(name),
    do: name in ~w(data-testid testid) or String.ends_with?(name, "_testid")

  defp id_of(value) do
    case Regex.run(~r/^\{?"([^"#]+)(#\{)?/, value) do
      [_, lit, _interpolated] -> lit <> "*"
      [_, lit] -> if String.ends_with?(lit, "-"), do: lit <> "*", else: lit
      nil -> nil
    end
  end

  defp bindings(attrs) do
    for {name, value} <- attrs,
        [_ | on] <- [Regex.run(@event_attr, name)],
        event <- bound_events(value) do
      paired = if on == [], do: ~w(data-testid testid), else: ["#{hd(on)}_testid"]
      id = Enum.find_value(attrs, fn {n, v} -> n in paired && id_of(v) end)
      {event, id, name}
    end
  end

  # Inside an expression only the literals it can send count: what JS.push
  # pushes, or the branches of a call-free expression such as an `if`.
  defp bound_events("{" <> _ = expr) do
    if String.contains?(expr, "(") do
      for [_, e] <- Regex.scan(~r/JS\.push\(\s*"([^"#]+)"/, expr), do: e
    else
      for [_, e] <- Regex.scan(~r/"([^"#]+)"/, expr), do: e
    end
  end

  defp bound_events(literal), do: [String.trim(literal, "\"")]

  defp handled(src) do
    clauses = for [_, e] <- Regex.scan(~r/def handle_event\(\s*"([^"]+)"/, src), do: e

    listed =
      for [_, words] <- Regex.scan(~r/@events\s+~w\(([^)]*)\)/, src), do: String.split(words)

    clauses ++ List.flatten(listed)
  end

  # A line that asserts a control is absent, or refutes it, does not drive it.
  @absence ~r/\brefute\b|(?<!not\.)toHaveCount\(0\)|\.not\.toBe(?:Visible|Attached)\(/

  defp test_names(tests) do
    for src <- Enum.map(tests, &drop_absence/1),
        [_, name] <-
          Regex.scan(~r/data-testid\s*\^?=\s*\\?["']?([\w.\/:@-]+)/, src) ++
            Regex.scan(~r/["'`]([\w.\/:@-]+)(?=["'`]|\$\{|#\{)/, src) ++
            for(
              [_, words] <- Regex.scan(~r/~w\(([^)]*)\)/, src),
              w <- String.split(words),
              do: [w, w]
            ),
        into: MapSet.new(),
        do: name
  end

  defp drop_absence(src) do
    src |> String.split("\n") |> Enum.reject(&Regex.match?(@absence, &1)) |> Enum.join("\n")
  end

  # A line that acts on a control: a browser action, a fixture helper that
  # drives its argument, or an ExUnit `render_*`, which may close a pipeline
  # started a line or two above.
  @acts ~r/\.(?:click|dblclick|fill|check|uncheck|selectOption|press)\(|\b(?:choose|openSection|closeSection|confirmEach|fillPluginForm)\(|render_(?:click|submit|change|hook|blur|focus|keydown|keyup)\(/

  defp acting_lines(src) do
    lines = String.split(src, "\n")

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, i} ->
      Regex.match?(@acts, line) or
        (Regex.match?(~r/\b(?:element|form)\(/, line) and
           lines |> Enum.slice(i + 1, 2) |> Enum.any?(&Regex.match?(~r/render_\w+\(/, &1)))
    end)
    |> Enum.map_join("\n", &elem(&1, 0))
  end

  defp driven_events(tests) do
    render =
      ~r/render_(?:click|submit|change|hook|blur|focus|keydown|keyup)\(\s*(?:[\w.@]+\s*,\s*)?"([^"#]+)"/

    for src <- tests, [_, e] <- Regex.scan(render, src), into: MapSet.new(), do: e
  end

  defp covered_ids(ids, names) do
    prefixes = for id <- ids, String.ends_with?(id, "*"), do: String.trim_trailing(id, "*")

    for name <- names, id = resolve(name, ids, prefixes), into: MapSet.new(), do: id
  end

  defp resolve(name, ids, prefixes) do
    if name in ids do
      name
    else
      prefixes
      |> Enum.filter(&String.starts_with?(name, &1))
      |> Enum.max_by(&String.length/1, fn -> nil end)
      |> then(&(&1 && &1 <> "*"))
    end
  end

  defp exempted(entries) do
    excused = MapSet.new(@exempt, &elem(&1, 0))
    Enum.reject(entries, &(elem(&1, 0) in excused))
  end

  defp label({_name, _file, label}), do: label
  defp label({name, _file}), do: name

  defp by_file(entries) do
    entries
    |> Enum.group_by(&elem(&1, 1), &label/1)
    |> Enum.sort()
    |> Enum.map_join("\n", fn {file, names} ->
      "#{file}: #{names |> Enum.uniq() |> Enum.join(", ")}"
    end)
  end
end
