defmodule FlezhaUi.NamingGateTest do
  @moduledoc """
  The tracked tree speaks core's vocabulary: relay, tasklet, cell, output, run.

  This is the only test that asserts a retired name is absent; a per-name
  absence check elsewhere would be a second gate to keep in step.
  """

  use ExUnit.Case, async: true

  alias FlezhaUi.NamingGate

  # Fewer files than this means the walk lost its scope, and a gate that reads
  # nothing passes everything.
  @files_floor 150

  test "the tracked tree holds no retired name" do
    hits = NamingGate.hits(NamingGate.files())

    assert hits == [],
           "retired names in the tracked tree (#{length(hits)}):\n" <>
             Enum.map_join(hits, "\n", &NamingGate.format/1)
  end

  test "every allowlist entry is still needed" do
    stale = NamingGate.stale_entries(NamingGate.all_files())

    assert stale == [],
           "allowlist entries that excuse nothing, delete them:\n" <>
             Enum.map_join(stale, "\n", fn {prefix, pattern, _} ->
               "#{prefix} × #{inspect(pattern)}"
             end)
  end

  test "the walk reads the tracked tree and leaves history out" do
    files = NamingGate.files()

    assert length(files) >= @files_floor
    refute Enum.any?(files, &String.starts_with?(&1, "openspec/changes/"))
    refute Enum.any?(files, &String.starts_with?(&1, "deps/"))
  end

  describe "the judge" do
    @planted [
      "an entity",
      "ProcJournal",
      "proc_idx",
      "kind: :stream",
      "durable_workflow",
      "role: :operator",
      ~s(role: "operator"),
      "io_listen",
      "topo-node-sink",
      "max_operatives",
      "OperativeLive",
      "compute_engine",
      "EventRelay",
      ~s(data-testid="stream-frames"),
      "/namespaces/default/relays/x/stream",
      "flezha-stylebook"
    ]

    @clean [
      "identity",
      "cooperative",
      ":proc_lib",
      "/proc/self",
      "io_listener",
      "list_sinks(ctx)",
      ~s(data-testid="sink-row"),
      ~s(phx-update="stream"),
      "stream(socket, :rows, rows)",
      "task_idx",
      "the operator using the console",
      "flezha_stylebook"
    ]

    for line <- @planted do
      test "flags #{inspect(line)}" do
        assert NamingGate.judge("lib/example.ex", unquote(line)) != []
      end
    end

    for line <- @clean do
      test "passes #{inspect(line)}" do
        assert NamingGate.judge("lib/example.ex", unquote(line)) == []
      end
    end

    test "judges code compiled on the controller in lib/ only" do
      assert NamingGate.judge("lib/example.ex", "Code.compile_string(src)") != []
      assert NamingGate.judge("README.md", "Code.compile_string(src)") == []
    end

    test "masks an allowlisted occurrence in its own path only" do
      assert NamingGate.judge(".claude/skills/x/SKILL.md", "the workflow") == []
      assert NamingGate.judge("README.md", "the workflow") != []
    end
  end
end
