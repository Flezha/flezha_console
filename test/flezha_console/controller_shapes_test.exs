defmodule FlezhaConsole.ControllerShapesTest do
  @moduledoc """
  The fake controller answers in the shapes the real one does.

  The shapes are recorded from the dev controller into
  `test/support/fixtures/controller_shapes.json` by
  `priv/dev/record_shapes.exs`, which every browser run also uses to check
  that the file still matches the controller.
  """

  use ExUnit.Case, async: true

  alias FlezhaConsole.ControllerShapes, as: Shapes

  @recorded "test/support/fixtures/controller_shapes.json"
  @external_resource @recorded

  @context %{source: :ui}

  # {read, path into its answer, a fixture built for that place}
  @builders [
    {"Relay.relay_rows", [1, "rows", :each], {:relay_row, ["relay_a"]}},
    {"Relay.graph", [1, "graph", "channels", :each],
     {:graph_channel, ["input", "input", "boundary", ["store"]]}},
    {"Relay.activity", [1, "tasklets", :each], {:activity_row, ["store"]}},
    {"Relay.activity cells_of", [1, "cells", "rows", :each], {:cell_row, ["a"]}},
    {"Fleet.providers", [1, "rows", :each],
     {:provider_entry, ["relay_websocket", "Flezha.Plugin.Provider.Websocket", true]}},
    {"Fleet.provider", [1, "options", :each], {:option_row, ["url"]}},
    {"Relay.registry", [1, :each], {:registry_entry, [:flow]}},
    {"Fleet.runners", [1, :each], {:runner_row, ["runner-a"]}},
    {"Logs.kinds", [1, :each], {:log_kind, ["relay_history"]}},
    {"Logs.read", [1, "records", :each], {:history_record, ["relay_a"]}},
    {"Logs.stats", [1, "controllers", :each], {:log_stats_row, [:"flezha@node-a"]}},
    {"Logs.files", [1, "files", :each],
     {:log_file_row, [:"flezha@node-a", "relay_history-20261029T130738Z-1.jsonl"]}}
  ]

  setup_all do
    %{recorded: @recorded |> File.read!() |> JSON.decode!()}
  end

  test "every read the recording names is one the console makes", %{recorded: recorded} do
    assert Enum.sort(Map.keys(recorded)) ==
             Enum.sort(for {label, _, _, _} <- Shapes.reads(), do: label)
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
      assert Shapes.diff(Shapes.of(%{opts: %{url: "x"}}), Shapes.of(%{opts: %{uri: "y"}})) == []
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
end
