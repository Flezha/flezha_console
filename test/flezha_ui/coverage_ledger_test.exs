defmodule FlezhaUi.CoverageLedgerTest do
  @moduledoc ~S"""
  Every event in `lib/` is driven through its markup by some test.

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
      what `JS.push/2` pushes, of each `on_<x>` attribute a component
      turns into a `phx-click`, and of the `click` attribute of a menu item or
      a segmented option. A binding is tied to the test id in its own tag:
      `data-testid` or `testid` for `phx-*` and `click`, `<x>_testid` for
      `on_<x>`.

  Read from `e2e/*.ts` and `test/**/*.exs`, this file aside, only the lines
  that act on a control count: a browser `click`, `fill`, `check`,
  `selectOption` or `press`, a fixture helper that drives its argument, an
  ExUnit `element/2` or `form/2` piped into a `render_*` call, or a row of a
  table-driven test naming the controls it clicks under `open:`, `cancel:` or
  `before:`. Lines that
  refute a control or assert it absent are left out. From those lines, each
  `data-testid=` or `data-testid^=` selector value, each `~w(...)` word and the
  leading literal of every string is a name. A name equal to an exact id names
  it; any other name names the longest prefix id it starts with, so
  `relay-row-relay_a` and `` `relay-row-${id}` `` both name `relay-row-*`.

  An event is driven when markup binds it to an id such a line names, when such
  a line selects its binding (`[phx-click="x"]`), or when `render_hook/3`
  pushes it, as a JS hook would. Pushing an event by name past the markup, as
  `render_click(view, "x")` does, drives nothing: it passes whatever the button
  is wired to. Coverage is by name across the tree, not per screen.

  An exemption names an event with the reason it can never be driven.
  """

  use ExUnit.Case, async: true

  alias FlezhaUi.NamingGate

  # Fewer than these means a pattern stopped matching, and a ledger that
  # collects nothing passes everything.
  @ids_floor 350
  @events_floor 100
  @bindings_floor 100

  # {test id or event, reason}
  @exempt []

  @own_file Path.relative_to_cwd(__ENV__.file)

  # A `{...}` expression: braces balanced, strings skipped whole.
  @expr ~S/(?(DEFINE)(?<x>\{(?:[^{}"]++|"(?:[^"\\]|\\.)*+"|(?&x))*+\}))/

  @event_attr ~r/^(?:phx-(?:click|click-away|capture-click|submit|change|blur|focus|keydown|keyup|window-[a-z]+|viewport-top|viewport-bottom|mounted|remove|connected|disconnected)|click|on_([a-z_]+))$/

  setup_all do
    %{ledger: ledger()}
  end

  test "every event in lib is driven by a test", %{ledger: ledger} do
    open = exempted(ledger.uncovered_events)

    assert open == [],
           "events no test drives through their markup (#{length(open)}):\n" <> by_file(open)
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
    open = Enum.map(ledger.uncovered_events ++ ledger.unhandled, &elem(&1, 0))

    stale = for {name, _reason} <- @exempt, name not in open, do: name

    assert stale == [], "exemptions that excuse nothing, delete them: #{Enum.join(stale, ", ")}"
  end

  test "the ledger reads lib and the tests", %{ledger: ledger} do
    assert ledger.ids >= @ids_floor
    assert ledger.events >= @events_floor
    assert ledger.bindings >= @bindings_floor
  end

  describe "what drives an event" do
    test "an event pushed by name past its markup drives nothing" do
      refute driven?(~s|render_click(view, "stop_relay", %{"id" => "stop-btn"})|, "stop_relay")
      refute acts_on?(~s|render_click(view, "stop_relay", %{"id" => "stop-btn"})|, "stop-btn")
    end

    test "a click on an element drives what its markup binds" do
      assert acts_on?(
               ~s|view \|> element(~s([data-testid="stop-btn"])) \|> render_click()|,
               "stop-btn"
             )

      assert acts_on?(
               ~s|view\n\|> element("[data-testid=stop-btn]")\n\|> render_click()|,
               "stop-btn"
             )
    end

    test "a selector on the binding drives the event it binds" do
      assert driven?(
               ~s|element(view, ~s(button[phx-click="stop_relay"])) \|> render_click()|,
               "stop_relay"
             )
    end

    test "a hook's event is driven by render_hook" do
      assert driven?(
               ~s|render_hook(view, "refresh_visibility", %{"hidden" => true})|,
               "refresh_visibility"
             )
    end

    test "a table row's open, cancel and before controls are acted on" do
      assert acts_on?(~s|        cancel: "schedule-run-cancel",|, "schedule-run-cancel")
      assert acts_on?(~s|        before: ["section-toggle-x"],|, "section-toggle-x")
      refute acts_on?(~s|        kept: "schedule-row-nightly"|, "schedule-row-nightly")
    end

    test "a browser action on an id acts on it, and asserting it absent does not" do
      assert acts_on?(~s|await page.getByTestId('stop-btn').click();|, "stop-btn")
      refute acts_on?(~s|await expect(page.getByTestId('stop-btn')).toHaveCount(0);|, "stop-btn")
    end

    defp driven?(src, event), do: event in driven_events([src], [acting_lines(src)])

    defp acts_on?(src, id),
      do: id in covered_ids(MapSet.new([id]), test_names([acting_lines(src)]))
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

    acting = Enum.map(tests, &acting_lines/1)
    driven = driven_events(tests, acting)
    acted = covered_ids(MapSet.new(ids, &elem(&1, 0)), test_names(acting))

    bound = for {event, id, _f, _attr} <- bindings, id in acted, into: MapSet.new(), do: event
    handled = MapSet.new(events, &elem(&1, 0))

    %{
      ids: length(ids),
      events: length(events),
      bindings: length(bindings),
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
          ~S'<[.:A-Za-z][\w.:-]*+(?<attrs>(?:\s++(?:(?&x)|[^\s=>{}"/]++(?:\s*+=\s*+(?:"[^"]*+"|(?&x)))?))*+)\s*+/?>'
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
  # drives its argument, an ExUnit `render_*` on an element, which may close a
  # pipeline started a line or two above, or a row of a table-driven test
  # naming the controls it clicks under `open:`, `cancel:` or `before:`. A
  # `render_*` given an event name pushes past the markup, so it acts on
  # nothing.
  @acts ~r/\.(?:click|dblclick|fill|check|uncheck|selectOption|press)\(|\b(?:choose|openSection|closeSection|confirmEach|fillPluginForm)\(|render_(?:click|submit|change|hook|blur|focus|keydown|keyup)\((?!\s*[\w.@]+\s*,\s*")|^\s*(?:open|cancel|before):\s/

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

  # A hook pushes its event by name, so `render_hook/3` is how a test drives
  # one; a selector on the binding itself drives what it is bound to.
  defp driven_events(tests, acting) do
    hooked = ~r/render_hook\(\s*(?:[\w.@]+\s*,\s*)?"([^"#]+)"/
    selected = ~r/phx-[a-z-]+=\\?["']([^"'\\#]+)/

    for(
      {src, lines} <- Enum.zip(tests, acting),
      [_, e] <- Regex.scan(hooked, src) ++ Regex.scan(selected, lines),
      into: MapSet.new(),
      do: e
    )
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
