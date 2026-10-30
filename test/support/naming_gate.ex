defmodule FlezhaConsole.NamingGate do
  @moduledoc """
  Judges tracked files against the vocabulary core has retired, and the tests
  against the waits a test must not make.

  Matching is by identifier component rather than by `\\b` word, so
  `max_operatives` and `entity_key` are caught while `cooperative` and
  `identity` are not. A path is judged as well as its lines.

  Scope is `git ls-files` with untracked files that are not ignored:
  `deps/`, `_build/`, `node_modules/` and `openspec/changes/` (the archive
  included) are outside it because they are ignored. A living spec is skipped while an open change on disk carries a
  delta for its capability, because archiving that change rewrites it.

  The allowlist names each occurrence that stays on purpose, by path prefix and
  text, with its reason. It is masked out of a line before the rules run, and
  an entry nothing needs any more is itself a failure.
  """

  @binary_ext ~w(.png .ico .woff .woff2 .jpg)
  @own_files ~w(test/support/naming_gate.ex test/flezha_console/naming_gate_test.exs)
  @legal ~w(LICENSE)

  # {pattern, the term to use instead, scope}
  @rules [
    {~r/(?:(?<![A-Za-z])|(?<=\\[ntr]))operatives?(?![a-z])/, "relay", :all},
    {~r/Operatives?(?![a-z])/, "Relay", :all},
    {~r/(?<![A-Z])OPERATIVES?(?![A-Z])/, "RELAY", :all},
    # Core's tasklet/cell patterns, split so each names its successor.
    {~r/(?:(?<![A-Za-z])|(?<=\\[ntr]))entit(?:y|ies)(?![a-z])/, "cell", :all},
    {~r/Entit(?:y|ies)(?![a-z])/, "Cell", :all},
    {~r/(?<![A-Z])ENTIT(?:Y|IES)(?![A-Z])/, "CELL", :all},
    {~r/(?:(?<![A-Za-z])|(?<=\\[ntr]))procedures?(?![a-z])/, "tasklet", :all},
    {~r/Procedures?(?![a-z])/, "Tasklet", :all},
    {~r/(?<![A-Z])PROCEDURES?(?![A-Z])/, "TASKLET", :all},
    {~r/(?<![A-Za-z])Procs?(?=[A-Z])(?!Parser\b)/, "Task", :all},
    {~r/(?<=[a-z0-9])Procs?(?![a-z])/, "Task", :all},
    {~r/(?<![A-Za-z])procs?_(?!macro|lib\b|parser\b|self_|open\b|close\b)/, "task_", :all},
    {~r/(?<=[a-z0-9])(?<!read)_procs?(?![a-z])/, "_task", :all},
    {~r/(?<![A-Za-z])PROCS?_/, "TASK_", :all},
    {~r/(?<![A-Za-z\/.])procs?[.-](?=journal|commit|inbox|boundar|index|idx|seq)/, "task", :all},
    # The retired kinds; a relay's run is its factory's `flow` or `steps`.
    {~r/(?<![A-Za-z0-9_:]):(?:stream|workflow|bounded|unbounded)(?![A-Za-z0-9_?!])/,
     "the factory's run (:flow | :steps)", :all},
    {~r/\bkind["']?\s*(?::|=>|=)\s*:?["']?(?:stream|bounded|unbounded)\b/, "run", :all},
    {~r/\bstream kinds?\b/, "run", :all},
    {~r/\b(?:input|filter)-kind\b/, "factory-run | filter-run", :all},
    {~r/workflow/i, "steps", :all},
    # The I/O tap became "listen".
    {~r/Stream(?:Live|Bridge|Registry|Supervisor)/, "ListenLive | EventFeed", :all},
    {~r/stream_(?:live|bridge|message|status)/, "listen_*", :all},
    {~r/(?<![A-Za-z0-9_-])stream-[a-z]/, "listen-", :all},
    {~r/(?<=[A-Za-z0-9_}])\/stream(?![A-Za-z0-9_-])/, "/listen", :all},
    # The topology graph's last node is the relay's output.
    {~r/sink_node/, "output_node", :all},
    {~r/topo-node-sink/, "topo-node-output", :all},
    {~r/(?<![A-Za-z0-9_:]):sink(?![A-Za-z0-9_?!])/, ":output", :all},
    {~r/(?<![A-Za-z0-9_:]):operator(?![A-Za-z0-9_?!])/, ":ops", :all},
    {~r/["']operator["']/, ~s("ops"), :all},
    {~r/(?<![A-Za-z0-9_])io_listen(?![A-Za-z0-9_])/, "Relay.listen/5", :all},
    {~r/compute_?engine/i, "runner", :all},
    {~r/processor/i, "tasklet", :all},
    {~r/response\(\)/, "output()", :all},
    # The remote-code path: nothing of this application runs on the controller.
    {~r/EventRelay|EventBridge/, "EventFeed", :all},
    {~r/event_relay|event_bridge/, "event_feed", :all},
    {~r/relay_source|compile_remote/, "nothing: no code is shipped to the controller", :all},
    {~r/(?<![A-Za-z0-9_])(?:relay_event|relay_error|tail_relay)(?![A-Za-z0-9_])/,
     "feed_event | feed_error | tail_feed", :all},
    {~r/Code\.compile_string|Node\.spawn/, "nothing: no code is run on the controller", :lib},
    {~r/flezha-stylebook/, "flezha_stylebook", :all},
    # A test waits only for a condition it caused, at its layer's default
    # timeout; a sleep, a timer or a raised limit waits out a cadence instead.
    {~r/\bsetTimeout\(|waitForTimeout\(|\btest\.slow\(/,
     "a condition the test caused, at the default timeout", :tests},
    {~r/\bintervals:/, "the default poll cadence", :e2e},
    {~r/\btimeout:\s*(?:(?:[5-9]|[1-9]\d+)_?\d{3}(?![\d_])|\d+\s*\*|[A-Z][A-Z0-9_]+)/,
     "the default timeout: cause the condition rather than wait for it", :e2e},
    {~r/(?:Process|:timer)\.sleep\(/, "a message or a synchronous call the test caused", :exunit},
    {~r/(?:assert|refute)_receive\b.*,\s*[1-9]\d*_?\d{3}\s*\)?\s*$/m,
     "the default receive timeout, after a synchronous barrier", :exunit}
  ]

  @scopes %{all: [""], lib: ["lib/"], tests: ["test/", "e2e/"], e2e: ["e2e/"], exunit: ["test/"]}

  # {path prefix, text, reason}
  @allowlist [
    {".claude/", ~r/workflow/i,
     "OpenSpec's generated commands and skills use the word for OpenSpec's own process"},
    {"", ~r/\.github\/workflows\//, "the directory GitHub reads CI definitions from"},
    {"test/flezha_console_web/live/console_navigation_test.exs", ~r/\/operatives/,
     "asserts the retired routes answer 404"},
    {"test/flezha_console_web/live/console_navigation_test.exs", ~r/\/stream(?![A-Za-z0-9_-])/,
     "asserts the retired routes answer 404"},
    {"openspec/specs/console-navigation/spec.md", ~r/\/operatives|\/stream(?![A-Za-z0-9_-])/,
     "the scenario that the retired routes answer 404 names them"},
    {"openspec/specs/dev-environment/spec.md", ~r/compute_engine|flezha-stylebook/,
     "the requirements that these names stay gone name them"},
    {"openspec/specs/runtime-events/spec.md", ~r/compute_engine/,
     "the requirement that the retired runner events stay gone names them"},
    {"openspec/specs/automated-testing/spec.md",
     ~r/operatives?|max_entities_per_operative|on_operative_init|procedure(_id)?|ProcJournal|ProcInbox|proc_journal|proc_inbox|entit(y|ies)|entity_key|:stream|:workflow|:bounded|:unbounded|workflow|:operator|"operator"|EventRelay|compute_engine|processor|response\(\)|io_listen|StreamLive|stream_live|StreamBridge|stream_bridge|flezha-stylebook/,
     "the naming gate's own requirement lists every name it bans"},
    {"e2e/global-setup.ts", ~r/setTimeout\(resolve, 500\)/,
     "global setup paces its reads of a controller that is still booting; no test has started"},
    {"test/support/peer_node.ex", ~r/Process\.sleep\(20\)/,
     "eventually/2 is the one sanctioned poll: short steps toward a condition the test caused"},
    {"lib/flezha_console_web/log_lines.ex", ~r/"operator"/,
     "core's relay history names a start an operator asked for by its origin kind, not by a role"},
    {"test/flezha_console_web/core/log_lines_test.exs", ~r/"operator"/,
     "core's relay history names a start an operator asked for by its origin kind, not by a role"},
    {"test/support/fake_controller.ex", ~r/"operator"/,
     "core's relay history names a start an operator asked for by its origin kind, not by a role"},
    {"test/support/fake_controller.ex", ~r/Process\.sleep\(:infinity\)/,
     "parks the process that owns the answer table; nothing waits on it"}
  ]

  @type hit :: %{file: String.t(), line: non_neg_integer(), term: String.t(), use: String.t()}

  @doc "Every tracked text file the gate reads, relative to `root`."
  @spec files(Path.t()) :: [String.t()]
  def files(root \\ File.cwd!()) do
    pending = pending_capabilities(root)

    root
    |> tracked()
    |> Enum.reject(&pending_spec?(&1, pending))
  end

  @doc """
  Every tracked text file, including living specs a pending change will
  rewrite. An allowlist entry is judged stale against this set, so an entry
  for a skipped spec is not reported stale.
  """
  @spec all_files(Path.t()) :: [String.t()]
  def all_files(root \\ File.cwd!()), do: tracked(root)

  @doc "Every retired name in `paths`, which are relative to `root`."
  @spec hits([String.t()], Path.t()) :: [hit()]
  def hits(paths, root \\ File.cwd!()) do
    paths
    |> Task.async_stream(&file_hits(&1, root), ordered: true, timeout: :infinity)
    |> Enum.flat_map(fn {:ok, hits} -> hits end)
  end

  defp file_hits(path, root) do
    entries = entries_for(path)
    path_hits = for {term, use} <- judge(path, path), do: hit(path, 0, term, use)
    file = Path.join(root, path)

    # Most files break no rule, so each rule is tried on the whole file once and
    # only the rules it breaks are tried line by line.
    masked = mask(read(file), entries)
    rules = Enum.filter(rules_for(path), &Regex.match?(elem(&1, 0), masked))

    line_hits =
      if rules == [] do
        []
      else
        file
        |> lines()
        |> Enum.flat_map(fn {text, n} ->
          for {term, use} <- apply_rules(rules, mask(text, entries)), do: hit(path, n, term, use)
        end)
      end

    path_hits ++ line_hits
  end

  @doc "The retired names on one line of the file at `path`, after the allowlist."
  @spec judge(String.t(), String.t()) :: [{String.t(), String.t()}]
  def judge(path, text), do: apply_rules(rules_for(path), mask(text, entries_for(path)))

  @doc "Allowlist entries that excuse nothing any more in `paths`."
  @spec stale_entries([String.t()], Path.t()) :: [{String.t(), Regex.t(), String.t()}]
  def stale_entries(paths, root \\ File.cwd!()) do
    # Compiled regexes do not compare equal across reads, so entries are told
    # apart by position.
    indexed = Enum.with_index(@allowlist)

    for {{prefix, pattern, _reason} = entry, i} <- indexed,
        not Enum.any?(Enum.filter(paths, &String.starts_with?(&1, prefix)), fn path ->
          others = for {e, j} <- indexed, j != i, String.starts_with?(path, elem(e, 0)), do: e

          root
          |> Path.join(path)
          |> lines()
          |> Enum.any?(fn {text, _n} ->
            Regex.match?(pattern, text) and apply_rules(rules_for(path), mask(text, others)) != []
          end)
        end),
        do: entry
  end

  @doc "A report line per hit: file, line and the term to use instead."
  @spec format(hit()) :: String.t()
  def format(%{file: file, line: 0, term: term, use: use}),
    do: "#{file} (path): #{inspect(term)} -> #{use}"

  def format(%{file: file, line: line, term: term, use: use}),
    do: "#{file}:#{line}: #{inspect(term)} -> #{use}"

  defp hit(file, line, term, use), do: %{file: file, line: line, term: term, use: use}

  defp tracked(root) do
    # Untracked files count too, so a new file is judged before it is staged.
    {out, 0} =
      System.cmd("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cd: root
      )

    out
    |> String.split(<<0>>, trim: true)
    |> Enum.reject(fn path ->
      Path.extname(path) in @binary_ext or path in @own_files or
        Path.basename(path) in @legal or not File.regular?(Path.join(root, path))
    end)
  end

  defp pending_capabilities(root) do
    root
    |> Path.join("openspec/changes/*/specs/*/spec.md")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/openspec/changes/archive/"))
    |> MapSet.new(&(&1 |> Path.dirname() |> Path.basename()))
  end

  defp pending_spec?(path, pending) do
    case Path.split(path) do
      ["openspec", "specs", cap, "spec.md"] -> MapSet.member?(pending, cap)
      _ -> false
    end
  end

  defp lines(file), do: file |> read() |> String.split("\n") |> Enum.with_index(1)

  # A file that is not valid UTF-8 is binary to the gate, and judged as empty.
  defp read(file) do
    content = File.read!(file)
    if String.valid?(content), do: content, else: ""
  end

  defp entries_for(path), do: Enum.filter(@allowlist, &String.starts_with?(path, elem(&1, 0)))

  defp rules_for(path) do
    Enum.filter(@rules, fn {_pattern, _use, scope} ->
      Enum.any?(Map.fetch!(@scopes, scope), &String.starts_with?(path, &1))
    end)
  end

  defp apply_rules(rules, text) do
    for {pattern, use, _scope} <- rules,
        [term | _] <- Regex.scan(pattern, text),
        uniq: true,
        do: {term, use}
  end

  defp mask(text, entries) do
    Enum.reduce(entries, text, fn {_prefix, pattern, _reason}, acc ->
      Regex.replace(pattern, acc, &String.duplicate(" ", byte_size(&1)))
    end)
  end
end
