defmodule FlezhaConsole.Service.ControllerShapesTest do
  @moduledoc """
  The fake controller answers in the shapes the real one does.

  The shapes are recorded from the dev controller into
  `priv/controller_shapes.json` by
  `priv/dev/record_shapes.exs`, which every browser run also uses to check
  that the file still matches the controller.
  """

  use ExUnit.Case, async: true

  alias FlezhaConsole.Service.ControllerShapes, as: Shapes

  @recorded "priv/controller_shapes.json"
  @external_resource @recorded

  @context %{source: :ui}

  # {read, path into its answer, a fixture built for that place}
  @builders [
    {"Relay.list", [1, "rows", :each], {:relay_row, ["relay_a"]}},
    {"Relay.graph", [1, "graph", "channels", :each],
     {:graph_channel, ["input", "input", "boundary", ["store"]]}},
    {"Relay.graph", [1, "graph", "tasklets", :each],
     {:graph_tasklet, ["store", %{compensates: true}]}},
    {"Fleet.factories", [1, "rows", :each], {:factory_row, ["fan_trade"]}},
    {"Fleet.factory", [1, "graph", "tasklets", :each],
     {:graph_tasklet, ["reserve", %{compensates: true}]}},
    {"Relay.activity", [1, "tasklets", :each], {:activity_row, ["store"]}},
    {"Relay.activity cells_of", [1, "cells", "rows", :each], {:cell_row, ["a"]}},
    {"Fleet.providers", [1, "rows", :each],
     {:provider_entry, ["relay_websocket", "Flezha.Plugin.Provider.Websocket", true]}},
    {"Fleet.provider", [1, "options", :each], {:option_row, ["url"]}},
    {"Fleet.runners", [1, :each], {:runner_row, ["runner-a"]}},
    {"Controller.liveness_counters relays", [1, "relays", :each],
     {:relay_counters, ["relay_a", %{io_in_received: 3}]}},
    {"Logs.kinds", [1, :each], {:log_kind, ["relay_history"]}},
    {"Logs.read", [1, "records", :each], {:history_record, ["relay_a"]}},
    {"Logs.stats", [1, "controllers", :each], {:log_stats_row, [:"flezha@node-a"]}},
    {"Logs.files", [1, "files", :each],
     {:log_file_row, [:"flezha@node-a", "relay_history-20261029T130738Z-1.jsonl"]}}
  ]

  setup_all do
    %{recorded: @recorded |> File.read!() |> JSON.decode!()}
  end

  test "every read the console makes is recorded", %{recorded: recorded} do
    assert for({label, _, _, _} <- Shapes.reads(), not Map.has_key?(recorded, label), do: label) ==
             []
  end

  for {label, module, function, args} <- Shapes.reads() do
    test "#{label} answers by default in the controller's shape", %{recorded: recorded} do
      answer =
        apply(unquote(module), unquote(function), unquote(Macro.escape(args)) ++ [@context])

      assert Shapes.diff(recorded[unquote(label)], Shapes.of(answer)) == []
    end
  end

  for {label, path, {builder, args}} <- @builders do
    test "FakeController.#{builder} builds what #{label} answers there", %{recorded: recorded} do
      recorded = Shapes.at(recorded[unquote(label)], unquote(Macro.escape(path)))
      built = apply(FakeController, unquote(builder), unquote(Macro.escape(args)))

      assert Shapes.diff(recorded, Shapes.of(built)) == []
    end
  end

  describe "a shape" do
    test "names a key the answer always carries that the fixture lacks" do
      recorded = Shapes.of(%{id: "a", health: :healthy})

      assert Shapes.diff(recorded, Shapes.of(%{id: "a"})) == [".health: missing"]

      assert Shapes.diff(recorded, Shapes.of(%{id: "a", health: :healthy, extra: 1})) ==
               [".extra: not in the answer"]
    end

    test "lets a fixture leave out a key the answer carries only sometimes" do
      recorded = Shapes.of([%{name: "a", default: 1}, %{name: "b"}])

      assert Shapes.diff(recorded, Shapes.of([%{name: "c"}])) == []
    end

    test "tells a list from a map, and a tag from another" do
      assert Shapes.diff(Shapes.of({:ok, []}), Shapes.of({:ok, %{}})) == [
               "{1}: a map keyed by data, the answer is a list"
             ]

      assert Shapes.diff(Shapes.of({:ok, 1}), Shapes.of({:error, 1})) == [
               "{0}: :error, the answer is :ok"
             ]
    end

    test "reads a map keyed by data as such, whichever keys an answer holds" do
      shape = fn health -> Shapes.of({:ok, %{relay_health: health, opts: %{url: "x"}}}) end

      assert Shapes.diff(shape.(%{healthy: 2}), shape.(%{healthy: 1, unknown: 1})) == []
    end

    test "reads no key of a map keyed by data as a field, even one named like one" do
      signal = %{count: 1, last_age_ms: 5}
      shape = fn signals -> Shapes.of(%{recent: %{signals: signals}}) end

      assert Shapes.diff(shape.(%{loaded: signal}), shape.(%{loaded: signal, refused: signal})) ==
               []
    end

    test "keeps only the presence of free-form options, whatever they hold" do
      recorded = Shapes.of(%{id: "r", opts: [bindings: [{"p", %{id: "p"}}]]})

      assert Shapes.diff(recorded, Shapes.of(%{id: "r", opts: [settings: %{run: :flow}, n: 1]})) ==
               []

      assert Shapes.diff(recorded, Shapes.of(%{id: "r"})) == [".opts: missing"]
    end

    test "takes a union as fitting when each of its alternatives fits" do
      recorded = Shapes.of([{"ns", %{id: "a"}}, {"ns", "runner", %{id: "b"}}])

      assert Shapes.diff(recorded, Shapes.of([{"ns", "runner", %{id: "c"}}])) == []
      assert Shapes.diff(recorded, Shapes.of([{"ns", %{id: "d"}}, {"ns", "r", %{id: "e"}}])) == []
      assert Shapes.diff(recorded, Shapes.of([{1, %{id: "d"}}, {"ns", "r", %{id: "e"}}])) != []
    end

    test "lets nil and an empty collection stand for any value" do
      assert Shapes.diff(Shapes.of(%{at: 1, rows: [%{id: "a"}]}), Shapes.of(%{at: nil, rows: []})) ==
               []
    end

    test "is recorded as one read per line with its keys sorted" do
      encoded = Shapes.encode(%{"b" => Shapes.of(%{z: 1, a: "x"}), "a" => Shapes.of([])})

      assert encoded ==
               ~s({\n  "a": {"list":"empty"},\n  "b": {"optional":[],"record":{"a":"string","z":"integer"}}\n}\n)
    end
  end

  describe "decoding" do
    defp decode(shape, json), do: Shapes.decode(Shapes.compile(shape), json)

    test "a record's keys become atoms, and its values are read by their shapes" do
      shape = Shapes.of(%{health: :healthy, id: "r1", at: ~U[2026-11-01 12:00:00Z]})

      assert decode(shape, %{"health" => "degraded", "id" => "r2", "at" => "2026-11-01T13:00:00Z"}) ==
               %{health: :degraded, id: "r2", at: ~U[2026-11-01 13:00:00Z]}
    end

    test "a dict keeps its keys as text" do
      assert decode(Shapes.of(%{"orders" => 1}), %{"orders" => 2, "audit" => 3}) ==
               %{"orders" => 2, "audit" => 3}
    end

    test "a dict keyed by atoms takes the atoms that exist, and keeps a mixed map's text keys" do
      verdicts = %{"dict" => "integer", "atoms" => "all"}
      assert decode(verdicts, %{"degraded" => 1}) == %{degraded: 1}

      entry = Shapes.of(%{:node => :flezha@a, "relay_class" => "orders"})

      assert decode(entry, %{"node" => "flezha@b", "relay_class" => "x"}) == %{
               "relay_class" => "x",
               node: "flezha@b"
             }
    end

    test "an atom is an existing atom, and a name no atom has stays text without making one" do
      name = "no_such_atom_#{System.unique_integer([:positive])}"
      before = :erlang.system_info(:atom_count)

      assert decode("atom", "healthy") == :healthy
      assert decode("atom", name) == name
      assert :erlang.system_info(:atom_count) == before
    end

    test "a node's name is always text" do
      assert Shapes.of(:flezha@a) == "node"
      assert decode("node", "flezha@b") == "flezha@b"
    end

    test "a tuple comes back from its array, the tag of an answer from its name" do
      assert decode(Shapes.of({:ok, "x", 1}), ["ok", "y", 2]) == {:ok, "y", 2}
      assert decode(Shapes.of({"ns", "r"}), ["ns", "r"]) == {"ns", "r"}
    end

    test "bytes that are not text come back from base64" do
      assert decode("string", %{"base64" => Base.encode64(<<255, 0>>)}) == <<255, 0>>
      assert decode("string", "plain") == "plain"
    end

    test "a pid, a reference or a function stays the text it crossed as" do
      assert decode(Shapes.of(%{pid: self()}), %{"pid" => "#PID<0.1.0>"}) == %{pid: "#PID<0.1.0>"}
    end

    test "a union is read as the alternative the JSON is, text before an atom" do
      shape = Shapes.merge(Shapes.of([:a]), Shapes.of(:a))
      assert decode(shape, ["a"]) == [:a]
      assert decode(shape, "a") == :a

      assert decode(Shapes.merge("atom", "string"), "healthy") == "healthy"
    end

    test "a key the recording does not name takes an existing atom, its value read as data" do
      shape = Shapes.of(%{id: "r1"})
      name = "unrecorded_#{System.unique_integer([:positive])}"

      assert decode(shape, %{"id" => "r1", "partition" => %{"index" => 1}, name => 1}) ==
               %{:id => "r1", :partition => %{index: 1}, name => 1}
    end

    test "free-form data takes existing atoms for its keys and keyword pairs, and keeps its values" do
      assert decode("data", %{"namespace" => "acme", "opts" => [["relay_class", "orders"]]}) ==
               %{namespace: "acme", opts: [relay_class: "orders"]}
    end

    test "an answer is the value of its :ok, a pair of values a list, a bare :ok itself" do
      assert Shapes.answer("Relay.stop", %{"id" => "r1", "stopped" => "cooperative"}) ==
               %{id: "r1", stopped: :cooperative}

      assert [%{"id" => "e1"}, "payload"] = Shapes.answer("Dlq.get", [%{"id" => "e1"}, "payload"])
      assert Shapes.answer("Steps.rewind", "ok") == :ok
    end
  end

  describe "the shipped recording" do
    # Every operation NodeManager names at its call sites, the token passed
    # first or piped in, and every event a stream delivers as core's HTTP API
    # documents them.
    @operations "lib/flezha_console/service/node_manager.ex"
                |> File.read!()
                |> then(
                  &Regex.scan(
                    ~r/\bauthorized_\w*(?:call|stream)\(\s*(?:token,\s*)?Flezha\.Service\.(\w+),\s*:(\w+)/,
                    &1
                  )
                )
                |> Enum.map(fn [_site, module, function] -> "#{module}.#{function}" end)
                |> Enum.uniq()
    @external_resource "lib/flezha_console/service/node_manager.ex"

    @events %{
      "Relay.listen" =>
        ~w(attached output input part dead_lettered call answered timed_out refused tally),
      "Logs.tail" => ["log"],
      "Observability.tail" => ["signal"]
    }

    test "holds a shape for every operation the console calls" do
      recorded = Shapes.recorded()

      missing =
        for operation <- @operations,
            not (operation in recorded or Enum.any?(recorded, &match?({^operation, _}, &1))),
            do: operation

      assert "Relay.list" in @operations
      assert missing == [], "no recorded shape for #{Enum.join(missing, ", ")}"
    end

    test "holds a shape for every event a stream delivers" do
      recorded = Shapes.recorded()

      missing =
        for {operation, names} <- @events,
            name <- names,
            {operation, name} not in recorded,
            do: "#{operation} #{name}"

      assert missing == [], "no recorded shape for #{Enum.join(missing, ", ")}"
    end
  end
end
