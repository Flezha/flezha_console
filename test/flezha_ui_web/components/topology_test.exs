defmodule FlezhaUiWeb.TopologyTest do
  @moduledoc """
  The topology's arithmetic and its joins, without a controller.

  These are the cases a live stack cannot be asked to produce on demand — a
  counter reset, a first tick with no baseline, a relay bound to a runner
  the fleet has dropped — and they are exactly the ones where a wrong answer
  would read as plausible on screen.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias FlezhaUiWeb.Topology

  @listener "Flezha.Plugin.Provider.MonitoredIOForward"

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{
        factory_id: "store_input",
        runner_id: "runner-a",
        run: :flow,
        suspended: false,
        effectively_once: false,
        default_input_type: nil,
        started_at: nil,
        uptime_ms: nil,
        relay_class: "relay_a",
        bindings: []
      },
      overrides
    )
  end

  defp binding(plugin_id, hook, position \\ nil) do
    %{plugin_id: plugin_id, hook: hook, provider: "Provider", position: position}
  end

  defp pipeline_input(overrides \\ %{}) do
    Map.merge(
      %{
        namespace: "default",
        relay_id: "relay_a",
        facts: facts(),
        snapshot: nil,
        history: [],
        parked: 0,
        verdicts: [],
        skew: nil,
        selected: nil
      },
      overrides
    )
  end

  defp summary_input(overrides \\ %{}) do
    Map.merge(
      %{
        namespace: "default",
        relay_ids: [],
        runners: [],
        snapshot: nil,
        rates: %{},
        dlq: [],
        verdicts: [],
        skew: nil
      },
      overrides
    )
  end

  defp node(graph, id), do: Enum.find(graph.nodes, &(&1.id == id))
  defp edge(graph, id), do: Enum.find(graph.edges, &(&1.id == id))

  defp lane(graph, lane),
    do: graph.nodes |> Enum.filter(&(&1.lane == lane)) |> Enum.map(& &1.kind)

  defp listener(id, hook), do: %{binding(id, hook) | provider: @listener}
  defp port(graph, id), do: Enum.find(graph.ports, &(&1.id == id))
  defp samples(values), do: Enum.map(values, &%{in: &1, out: &1, filtered: 0, parked: 0})

  describe "pipeline/1 structure" do
    test "a relay with nothing bound is still a full record lane, ending in its output" do
      graph = Topology.pipeline(pipeline_input())

      assert lane(graph, :record) == [:ingest, :core, :channel, :output]
      assert lane(graph, :life) == []
      assert graph.plugin_count == 0
      assert Enum.map(graph.ports, & &1.id) == ["in", "out"]
    end

    test "input and output plugins sit on the record lane, in position order" do
      bindings = [
        binding("late_out", "on_output", 1),
        binding("early_in", "on_input", 0),
        binding("early_out", "on_output", 0)
      ]

      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{bindings: bindings})}))
      record = Enum.filter(graph.nodes, &(&1.lane == :record))

      assert Enum.map(record, & &1.label) ==
               ~w(Ingest early_in relay_a early_out late_out runner-a Output)

      # Left to right, on one row.
      assert Enum.map(record, & &1.x) == Enum.sort(Enum.map(record, & &1.x))
      assert record |> Enum.map(& &1.y) |> Enum.uniq() |> length() == 1
    end

    test "an off-path hook is a lifecycle chip over the core, not a step" do
      bindings = [binding("ticker", "on_interval"), binding("feeder", "on_input", 0)]

      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{bindings: bindings})}))
      chip = node(graph, "plugin-ticker")
      core = node(graph, "relay_a")

      assert lane(graph, :record) == [:ingest, :plugin, :core, :channel, :output]
      assert chip.lane == :life and chip.y < core.y
      assert chip.x + div(chip.w, 2) == core.x + div(core.w, 2)
      assert edge(graph, "branch-plugin-ticker").kind == :satellite
    end

    test "a plugin on a path hook and a lifecycle hook is one step and one chip, every id unique" do
      bindings = [binding("audit", "on_input", 0), binding("audit", "on_terminate")]

      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{bindings: bindings})}))
      ids = Enum.map(graph.nodes, & &1.id) ++ Enum.map(graph.edges, & &1.id)

      assert node(graph, "plugin-audit-on_input").lane == :record
      assert node(graph, "plugin-audit").lane == :life
      assert ids == Enum.uniq(ids)
      assert graph.plugin_count == 1
    end

    test "a relay bound to no runner reports an unbound channel and a degraded edge" do
      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{runner_id: nil})}))

      assert node(graph, "channel").state == :unbound
      assert node(graph, "channel").label == "unbound"
      assert edge(graph, "flow-relay_a-channel").degraded?
    end

    test "both ends of the failures lane are drawn at zero, muted, where they stay" do
      empty = Topology.pipeline(pipeline_input())
      parked = Topology.pipeline(pipeline_input(%{parked: 4}))

      assert lane(empty, :fail) == [:filtered, :dead_letter]
      assert node(empty, "dead-letter").muted? and node(empty, "filtered").muted?
      assert node(parked, "dead-letter").sub == "4 parked"
      refute node(parked, "dead-letter").muted?

      assert Map.take(node(parked, "dead-letter"), [:x, :y]) ==
               Map.take(node(empty, "dead-letter"), [:x, :y])

      assert edge(parked, "branch-dead-letter").kind == :dlq
    end

    test "a suspended relay is styled apart" do
      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{suspended: true})}))

      assert node(graph, "relay_a").state == :suspended
    end

    test "a channel whose credit ran dry reports backpressure, and the relay reads Stuck" do
      snapshot = %{
        channels: [
          %{runner_id: "runner-a", name: :chan_a, credit_active: 1, credit_ledger_level: 0}
        ],
        relays: []
      }

      graph =
        Topology.pipeline(
          pipeline_input(%{
            snapshot: snapshot,
            history: samples([40, 40]),
            modes: %{in: :streaming, out: :streaming}
          })
        )

      assert node(graph, "channel").backpressure?
      assert node(graph, "channel").channel.name == "chan_a"
      assert edge(graph, "flow-relay_a-channel").stopped?
      refute edge(graph, "flow-ingest-relay_a").stopped?
      assert graph.flow.word == :stuck
    end
  end

  describe "pipeline/1 observers" do
    test "listeners are counted on the point they watch and drawn as no node" do
      bindings = [
        binding("guard", "on_input", 0),
        listener("io_listener_a", "on_input"),
        listener("io_listener_b", "on_output"),
        listener("io_listener_b", "on_preview"),
        listener("io_listener_c", "on_call")
      ]

      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{bindings: bindings})}))

      assert port(graph, "in").observers == ["io_listener_a"]
      assert port(graph, "out").observers == ["io_listener_b"]
      assert node(graph, "relay_a").observers == ["io_listener_c"]
      refute Enum.any?(graph.nodes, &String.contains?(&1.id, "io_listener"))
      assert {graph.plugin_count, graph.observer_count} == {1, 3}
    end

    test "listeners coming and going move no node" do
      plain = [binding("guard", "on_input", 0), binding("ticker", "on_interval")]

      listened =
        plain ++ [listener("io_listener_a", "on_input"), listener("io_listener_b", "on_output")]

      place = fn bindings ->
        pipeline_input(%{facts: facts(%{bindings: bindings})})
        |> Topology.pipeline()
        |> Map.fetch!(:nodes)
        |> Map.new(&{&1.id, {&1.x, &1.y, &1.w, &1.h}})
      end

      assert place.(listened) == place.(plain)
    end

    test "the header counts one plugin on two hooks once, and an output listener apart" do
      bindings = [
        binding("audit", "on_input", 0),
        binding("audit", "on_output", 0),
        listener("io_listener_b", "on_output"),
        listener("io_listener_b", "on_preview")
      ]

      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{bindings: bindings})}))

      assert {graph.plugin_count, graph.observer_count} == {1, 1}
    end
  end

  describe "pipeline/1 rates and recency" do
    test "the ports show the mean of the newest seven samples" do
      history = samples([100, 0, 0, 7, 0, 0, 7, 0, 0])

      graph = Topology.pipeline(pipeline_input(%{history: history}))

      # 0+7+0+0+7+0+0 over seven: the burst nine ticks ago has left the window.
      assert port(graph, "in").label == "2.0/s"
      assert port(graph, "out").rate == 2.0
      assert edge(graph, "flow-channel-output").label == "2.0/s"
    end

    test "a trickle under one decimal reads <0.1/s, and no baseline reads nothing" do
      assert Topology.rate_label(0.04) == "<0.1/s"
      assert Topology.rate_label(+0.0) == "0.0/s"
      assert Topology.rate_label(nil) == nil

      graph = Topology.pipeline(pipeline_input())
      assert port(graph, "in").label == nil
      assert port(graph, "in").state == "measuring"
    end

    test "edges between plugins carry no figure and say they are not counted" do
      bindings = [binding("a", "on_input", 0), binding("b", "on_input", 1)]

      graph =
        Topology.pipeline(
          pipeline_input(%{facts: facts(%{bindings: bindings}), history: samples([3])})
        )

      between = edge(graph, "flow-plugin-a-on_input-plugin-b-on_input")
      assert between.rate == nil
      assert between.title =~ "Not counted"
      assert edge(graph, "flow-ingest-plugin-a-on_input").rate == 3.0
    end

    test "each port states when a record last passed, or how long it has been quiet" do
      input =
        pipeline_input(%{
          history: samples([1, 0, 0]),
          now: 100_000,
          opened_at: 0,
          seen: %{in: 96_000, out: nil},
          modes: %{in: :trickling, out: :quiet}
        })

      graph = Topology.pipeline(input)

      assert port(graph, "in").state == "last record ~4 s ago"
      assert port(graph, "out").state == "quiet for 1m 40s"
      assert edge(graph, "flow-ingest-relay_a").title =~ "last record ~4 s ago"

      quiet =
        Topology.pipeline(%{
          input
          | seen: %{in: 20_000, out: nil},
            modes: %{in: :quiet, out: :quiet}
        })

      assert port(quiet, "in").state == "quiet for 1m 20s"
    end

    test "a stall verdict marks the node it names" do
      core = Topology.pipeline(pipeline_input(%{verdicts: [%{layer: :x, subject: "relay_a"}]}))
      runner = Topology.pipeline(pipeline_input(%{verdicts: [%{layer: :x, subject: "runner-a"}]}))
      elsewhere = Topology.pipeline(pipeline_input(%{verdicts: [%{layer: :x, subject: "other"}]}))

      assert node(core, "relay_a").stalled?
      refute node(core, "channel").stalled?
      assert node(runner, "channel").stalled?
      refute Enum.any?(elsewhere.nodes, & &1[:stalled?])
    end

    test "the newest verdict is the one bannered" do
      verdicts = [
        %{layer: :relay_not_forwarding, subject: "relay_a"},
        %{layer: :older, subject: nil}
      ]

      graph = Topology.pipeline(pipeline_input(%{verdicts: verdicts}))

      assert graph.stall.layer == :relay_not_forwarding
    end
  end

  describe "wire_mode/3" do
    test "streams from 5/s and keeps streaming until the rate falls to 3/s" do
      assert Topology.wire_mode(:trickling, 5.0, 0) == :streaming
      assert Topology.wire_mode(:trickling, 4.0, 0) == :trickling
      assert Topology.wire_mode(:streaming, 4.0, 0) == :streaming
      assert Topology.wire_mode(:streaming, 3.0, 0) == :trickling
    end

    test "trickles while a record passed within 30 s, and is quiet after" do
      assert Topology.wire_mode(:quiet, 0.1, 30_000) == :trickling
      assert Topology.wire_mode(:trickling, 0.1, 30_001) == :quiet
      assert Topology.wire_mode(:quiet, nil, nil) == :quiet
    end
  end

  describe "pipeline/1 state and timeline" do
    defp word(history, mode),
      do:
        Topology.pipeline(pipeline_input(%{history: history, modes: %{in: mode, out: mode}})).flow

    test "a moving relay reads by its input's state, with its figures" do
      history = Enum.map(1..7, fn _ -> %{in: 120.0, out: 108.0, filtered: 12.0, parked: 0} end)

      assert %{word: :streaming, sentence: sentence} = word(history, :streaming)
      assert sentence =~ "120.0/s in"
      assert sentence =~ "108.0/s delivered"
      assert sentence =~ "10% filtered"
      assert word(samples([0.2]), :trickling).word == :trickle
      assert word(samples([0]), :quiet).word == :quiet
    end

    test "Failing outranks Streaming once over a tenth of two ticks' intake parked" do
      history = [%{in: 50.0, out: 40.0, parked: 6.0}, %{in: 50.0, out: 40.0, parked: 6.0}]

      assert %{word: :failing, sentence: sentence} = word(history, :streaming)
      assert sentence =~ "12% of what came in"
      assert word([%{in: 50.0, out: 50.0, parked: 4.0}], :streaming).word == :streaming
    end

    test "the timeline draws a bar where each row moved, newest at the right" do
      history = [
        %{in: 30.0, out: 30.0, filtered: 0, parked: 0},
        %{in: 0, out: 0, filtered: 2.0, parked: 1.0}
      ]

      timeline = Topology.pipeline(pipeline_input(%{history: history})).timeline
      rows = Map.new(timeline.rows, &{&1.key, &1.bars})

      assert timeline.samples == 2
      assert [%{x: x_in}] = rows.in
      assert [%{x: x_parked}] = rows.parked
      assert length(rows.out) == 1 and length(rows.filtered) == 1
      assert x_parked > x_in
      assert x_parked + 10 == timeline.width
    end

    test "tracing the dead-letter route reaches back through the core to Ingest" do
      bindings = [binding("guard", "on_input", 0), binding("fan", "on_output", 0)]
      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{bindings: bindings})}))
      on_dlq = fn routes -> "dlq" in String.split(routes) end

      assert on_dlq.(node(graph, "ingest").routes)
      assert on_dlq.(node(graph, "plugin-guard-on_input").routes)
      assert on_dlq.(node(graph, "relay_a").routes)
      assert on_dlq.(edge(graph, "branch-dead-letter").routes)
      refute on_dlq.(node(graph, "plugin-fan-on_output").routes)
      refute on_dlq.(node(graph, "output").routes)
      refute on_dlq.(port(graph, "out").routes)
    end

    test "each box says where a dot's route crosses it, so the dot passes through it" do
      bindings = [
        binding("guard", "on_input", 0),
        binding("fan", "on_output", 0),
        binding("ticker", "on_interval")
      ]

      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{bindings: bindings})}))
      crossing = &Map.take(node(graph, &1), [:flow, :at, :until])

      assert crossing.("ingest") == %{flow: "in", at: 0.0, until: 0.0}
      assert %{flow: "in", at: at, until: until} = crossing.("plugin-guard-on_input")
      assert 0 < at and at < until and until < 1
      assert crossing.("relay_a") == %{flow: "in", at: 1.0, until: 1.0}
      assert %{flow: "out", at: at, until: until} = crossing.("plugin-fan-on_output")
      assert 0 < at and at < until and until < 1
      assert crossing.("output") == %{flow: "out", at: 1.0, until: 1.0}
      assert crossing.("dead-letter") == %{flow: "dlq", at: 1.0, until: 1.0}
      assert crossing.("plugin-ticker") == %{}

      html = render_component(&Topology.pipeline_graph/1, topology: graph, tapped: nil)
      assert html =~ ~s(data-flow="in" data-at="1.0" data-until="1.0")
    end
  end

  describe "pipeline_graph/1" do
    test "renders the ports, the dock hint, the timeline and the not-counted tooltip" do
      bindings = [binding("a", "on_input", 0), binding("b", "on_input", 1)]

      graph =
        Topology.pipeline(
          pipeline_input(%{
            facts: facts(%{bindings: bindings}),
            history: samples([1]),
            selected: "relay_a"
          })
        )

      html = render_component(&Topology.pipeline_graph/1, topology: graph, tapped: "output")

      assert html =~ ~s(data-testid="topo-port-in")

      assert html =~
               ~r/data-testid="topo-port-out"[^>]*class="topo-port is-tapped"|class="topo-port is-tapped"[^>]*data-testid="topo-port-out"/

      assert html =~ ~s(data-testid="topology-timeline" data-samples="1")
      assert html =~ "Not counted: the controller keeps no counter between plugins"
      assert html =~ ~s(data-testid="topology-detail")
      assert html =~ ~s(id="route-dlq")
    end
  end

  describe "summary/1" do
    test "counts what is running" do
      view =
        Topology.summary(
          summary_input(%{relay_ids: ["relay_a", "relay_b"], runners: ["runner-a"]})
        )

      assert view.state == :ok
      assert view.relay_count == 2
      assert view.runner_count == 1
    end

    test "a namespace with nothing in it is empty rather than zeroed" do
      assert Topology.summary(summary_input()).state == :empty
    end

    test "names the runners whose channels ran out of credit" do
      snapshot = %{
        channels: [
          %{runner_id: "runner-a", name: :a, credit_active: 1, credit_ledger_level: 0},
          %{runner_id: "runner-b", name: :b, credit_active: 1, credit_ledger_level: 2_048}
        ],
        relays: []
      }

      view =
        Topology.summary(summary_input(%{runners: ["runner-a", "runner-b"], snapshot: snapshot}))

      assert view.backpressured == ["runner-a"]
    end

    test "sums dead-letter pressure across classes" do
      dlq = [
        %{relay_class: "relay_a", tasklet_id: "t", entries: 3},
        %{relay_class: "relay_b", tasklet_id: "t", entries: 4}
      ]

      assert Topology.summary(summary_input(%{dlq: dlq})).parked == 7
    end

    test "ranks the busiest relays and links each to its pipeline" do
      rates = %{
        "quiet" => %{in: 1.0, out: 1.0},
        "busy" => %{in: 90.0, out: 80.0},
        "middling" => %{in: 10.0, out: 10.0}
      }

      view =
        Topology.summary(summary_input(%{relay_ids: ["quiet", "busy", "middling"], rates: rates}))

      assert Enum.map(view.busiest, & &1.id) == ["busy", "middling", "quiet"]
      assert hd(view.busiest).href == "/namespaces/default/relays/busy"
    end

    test "a relay that has gone away is not ranked on its last rate" do
      rates = %{"gone" => %{in: 500.0, out: 500.0}, "here" => %{in: 1.0, out: 1.0}}

      view = Topology.summary(summary_input(%{relay_ids: ["here"], rates: rates}))

      assert Enum.map(view.busiest, & &1.id) == ["here"]
    end

    test "the ranking is capped so a large fleet cannot flood the panel" do
      ids = Enum.map(1..20, &"relay_#{&1}")
      rates = Map.new(ids, &{&1, %{in: 1.0, out: 1.0}})

      assert length(Topology.summary(summary_input(%{relay_ids: ids, rates: rates})).busiest) ==
               5
    end
  end

  describe "rates/3" do
    defp snapshot(relays), do: %{channels: [], relays: relays}

    defp counters(id, received, forwarded, filtered \\ 0) do
      %{relay_id: id, io_in_received: received, forwarded: forwarded, filtered_nil: filtered}
    end

    test "advancing counters over elapsed time become messages per second" do
      previous = snapshot([counters("relay_a", 100, 90, 4)])
      current = snapshot([counters("relay_a", 140, 120, 10)])

      assert %{"relay_a" => %{in: 20.0, out: 15.0, filtered: 3.0}} =
               Topology.rates(current, previous, 2_000)
    end

    test "a first snapshot has no baseline and so no rates" do
      assert Topology.rates(snapshot([counters("relay_a", 100, 90)]), nil, 2_000) == %{}
    end

    test "a missing snapshot yields no rates" do
      assert Topology.rates(nil, snapshot([counters("relay_a", 1, 1)]), 2_000) == %{}
    end

    test "two snapshots with no elapsed time yield no rates rather than dividing by zero" do
      previous = snapshot([counters("relay_a", 100, 90)])

      assert Topology.rates(snapshot([counters("relay_a", 140, 120)]), previous, 0) == %{}
    end

    test "counters that went backwards clamp to zero for the tick" do
      # What a controller restart looks like from here.
      previous = snapshot([counters("relay_a", 5_000, 4_900)])
      current = snapshot([counters("relay_a", 12, 8)])

      assert %{"relay_a" => %{in: +0.0, out: +0.0}} = Topology.rates(current, previous, 2_000)
    end

    test "a relay absent from the previous snapshot gets no rate until it has a baseline" do
      previous = snapshot([counters("relay_a", 100, 90)])
      current = snapshot([counters("relay_a", 120, 110), counters("relay_b", 7, 7)])

      rates = Topology.rates(current, previous, 1_000)

      assert Map.has_key?(rates, "relay_a")
      refute Map.has_key?(rates, "relay_b")
    end
  end

  describe "push_history/2" do
    test "keeps the newest sample first" do
      history =
        Topology.push_history(%{"relay_a" => [%{in: 1.0, out: 1.0}]}, %{
          "relay_a" => %{in: 2.0, out: 2.0}
        })

      assert [%{in: 2.0}, %{in: 1.0}] = history["relay_a"]
    end

    test "caps each relay at sixty samples" do
      samples = List.duplicate(%{in: 1.0, out: 1.0}, 60)

      history =
        Topology.push_history(%{"relay_a" => samples}, %{"relay_a" => %{in: 9.0, out: 9.0}})

      assert length(history["relay_a"]) == 60
      assert hd(history["relay_a"]) == %{in: 9.0, out: 9.0}
    end
  end

  describe "speed_bucket/1" do
    test "no rate and no flow are both idle" do
      assert Topology.speed_bucket(nil) == :idle
      assert Topology.speed_bucket(+0.0) == :idle
    end

    test "each bucket ends where the next begins" do
      assert Topology.speed_bucket(0.1) == :slow
      assert Topology.speed_bucket(9.9) == :slow
      assert Topology.speed_bucket(10.0) == :medium
      assert Topology.speed_bucket(99.9) == :medium
      assert Topology.speed_bucket(100.0) == :fast
    end
  end

  describe "map/1" do
    defp map_row(id, overrides \\ %{}) do
      Map.merge(
        %{
          id: id,
          health: :healthy,
          runner: "runner-a",
          factory: "f_#{id}",
          partition: nil,
          node: :flezha@a
        },
        overrides
      )
    end

    defp lanes(map), do: Enum.flat_map(map.bands, & &1.lanes)

    test "on_input bindings become sources and on_output ones outputs, wired to their lanes" do
      plugins = [
        {"orders",
         [
           {"ws_in", %{hooks: [:on_input], provider: Ws}},
           {"kafka_out", %{hooks: [{:on_output, []}], provider: K}}
         ]}
      ]

      map =
        Topology.map(%{
          namespace: "default",
          rows: [map_row("orders"), map_row("plain")],
          runners: [%{id: "runner-a", pid: 42}],
          plugins: plugins
        })

      # Each source sits level with the lanes it feeds: orders comes first.
      assert Enum.map(map.sources, & &1.id) == ["in-ws_in", "calls"]
      assert Enum.map(map.outputs, & &1.id) == ["out-kafka_out", "stream"]
      assert Enum.find(map.sources, &(&1.id == "in-ws_in")).inspect == {:plugin, "ws_in"}

      wires = Enum.map(map.wires, & &1.id)
      assert "in-ws_in->relay-orders" in wires
      assert "relay-orders->out-kafka_out" in wires
      # A lane no input plugin feeds is fed by calls and sends, and one no
      # output plugin carries leaves on the runner stream.
      assert "calls->relay-plain" in wires
      assert "relay-plain->stream" in wires
    end

    test "a relay sits in its runner's band, and one with no runner in the unbound zone" do
      map =
        Topology.map(%{
          namespace: "default",
          rows: [map_row("orders"), map_row("testnet_echo", %{runner: nil, health: :suspended})],
          runners: [%{id: "runner-a", pid: 42}]
        })

      assert [%{id: "runner-a", pid: 42, lanes: [%{id: "orders"}]}] = map.bands
      assert [%{id: "testnet_echo", tone: :warning, state: state}] = map.zone.lanes
      assert state =~ "waiting for a runner"
      # Unbound, so no runner stream to reach.
      refute Enum.any?(map.wires, &(&1.id == "relay-testnet_echo->stream"))
    end

    test "more than three relays of one factory stack, until the stack is opened" do
      rows = for i <- 1..4, do: map_row("store_#{i}", %{factory: "store_input"})

      input = %{
        namespace: "default",
        rows: rows ++ [map_row("other")],
        runners: [%{id: "runner-a"}]
      }

      assert [%{id: "other"}, stack] = lanes(Topology.map(input))
      assert stack.kind == :stack
      assert stack.label == "store_input ×4"
      assert stack.members == ~w(store_1 store_2 store_3 store_4)
      assert stack.sub =~ "4 healthy"

      opened = Topology.map(Map.put(input, :expanded, MapSet.new(["runner-a/store_input"])))
      assert length(lanes(opened)) == 5
    end

    test "three of one factory do not stack" do
      rows = for i <- 1..3, do: map_row("s_#{i}", %{factory: "same"})

      assert Enum.all?(
               lanes(Topology.map(%{namespace: "d", rows: rows, runners: [%{id: "runner-a"}]})),
               &(&1.kind == :relay)
             )
    end

    test "a band draws twelve lanes and then +N more, linked to the relays index by runner" do
      rows = for i <- 1..15, do: map_row("r_#{String.pad_leading("#{i}", 2, "0")}")

      [band] =
        Topology.map(%{namespace: "default", rows: rows, runners: [%{id: "runner-a"}]}).bands

      assert length(band.lanes) == 12
      assert band.more.count == 3
      assert band.more.href == "/namespaces/default/relays?runner=runner-a"
    end

    test "the unbound zone draws twelve lanes and then +N more, linked to the relays index" do
      rows =
        for i <- 1..15, do: map_row("u_#{String.pad_leading("#{i}", 2, "0")}", %{runner: nil})

      zone = Topology.map(%{namespace: "default", rows: rows, runners: []}).zone

      assert length(zone.lanes) == 12
      assert zone.more.count == 3
      assert zone.more.href == "/namespaces/default/relays"
    end

    test "a partition group's copies of a plugin are one node, wired to every member" do
      rows =
        for i <- 0..2 do
          map_row("demo#p#{i}", %{factory: "market", partition: %{group: "demo", index: i}})
        end

      plugins =
        for i <- 0..2,
            do: {"demo#p#{i}", [{"ohlc#p#{i}", %{hooks: [:on_output], provider: K}}]}

      map =
        Topology.map(%{
          namespace: "default",
          rows: rows,
          runners: [%{id: "runner-a"}],
          plugins: plugins,
          expanded: MapSet.new(["runner-a/market"])
        })

      assert [
               %{
                 id: "out-ohlc",
                 label: "ohlc ×3",
                 inspect: nil,
                 link: %{navigate: "/namespaces/default/plugins"}
               },
               _stream
             ] =
               map.outputs

      wires = Enum.map(map.wires, & &1.id)
      assert Enum.all?(0..2, &("relay-demo#p#{&1}->out-ohlc" in wires))
    end

    test "a group of one keeps its copy's own name and inspector" do
      rows = [map_row("solo#p0", %{partition: %{group: "solo", index: 0}})]
      plugins = [{"solo#p0", [{"feed#p0", %{hooks: [:on_input], provider: K}}]}]

      map =
        Topology.map(%{
          namespace: "d",
          rows: rows,
          runners: [%{id: "runner-a"}],
          plugins: plugins
        })

      assert %{label: "feed#p0", inspect: {:plugin, "feed#p0"}} =
               Enum.find(map.sources, &(&1.id == "in-feed"))
    end

    test "a column draws its eight most-wired plugins and folds the rest into +N more" do
      rows = for i <- 1..12, do: map_row("r_#{String.pad_leading("#{i}", 2, "0")}")

      plugins =
        for i <- 1..12 do
          id = "r_#{String.pad_leading("#{i}", 2, "0")}"
          {id, [{"in_#{id}", %{hooks: [:on_input], provider: Ws}}]}
        end

      map =
        Topology.map(%{
          namespace: "default",
          rows: rows,
          runners: [%{id: "runner-a"}],
          plugins: plugins
        })

      assert length(map.sources) == 10

      assert %{label: "+4 more", link: %{navigate: "/namespaces/default/plugins"}} =
               Enum.find(map.sources, &(&1.id == "more-in"))

      # Every lane is still fed: a folded plugin's lane from the +N more node.
      fed = map.wires |> Enum.map(& &1.id) |> Enum.filter(&String.contains?(&1, "->relay-"))
      assert length(fed) == 12
      assert Enum.count(fed, &String.starts_with?(&1, "more-in->")) == 4
    end

    test "runners past the fourth fold into one row, those needing attention kept first" do
      runners = for i <- 1..6, do: %{id: "runner-#{i}"}

      rows =
        for i <- 1..6 do
          map_row("r_#{i}", %{
            runner: "runner-#{i}",
            health: if(i == 6, do: :failed, else: :healthy)
          })
        end

      map = Topology.map(%{namespace: "default", rows: rows, runners: runners})

      assert Enum.map(map.bands, & &1.id) == ~w(runner-6 runner-1 runner-2 runner-3)

      assert %{label: "+2 more runners", sub: "2 relays, listed under Runners"} =
               map.more_runners

      assert map.more_runners.link == %{href: "#runners"}
    end

    test "the folded runners and the zone's overflow render as links" do
      runners = for i <- 1..5, do: %{id: "runner-#{i}"}
      bound = for i <- 1..5, do: map_row("r_#{i}", %{runner: "runner-#{i}"})
      unbound = for i <- 1..13, do: map_row("u_#{i}", %{runner: nil})

      html =
        render_component(&Topology.namespace_map/1,
          map: Topology.map(%{namespace: "default", rows: bound ++ unbound, runners: runners})
        )

      assert html =~ ~r/data-testid="map-more-runners"[^>]*>/
      assert html =~ ~s(href="#runners")
      assert html =~ "+1 more runner"
      assert html =~ ~r/data-testid="map-more-unbound"/
      assert html =~ ~s(href="/namespaces/default/relays")
    end

    test "a namespace of a hundred relays draws a map of bounded height" do
      runners = for i <- 1..8, do: %{id: "runner-#{i}"}

      rows =
        for i <- 1..100 do
          map_row("r_#{i}", %{
            runner: if(i > 80, do: nil, else: "runner-#{rem(i, 8) + 1}"),
            factory: "f_#{i}",
            partition: %{group: "g_#{rem(i, 5)}", index: i}
          })
        end

      plugins =
        for i <- 1..100 do
          {"r_#{i}",
           [
             {"in_#{i}", %{hooks: [:on_input], provider: Ws}},
             {"out_#{i}", %{hooks: [:on_output], provider: K}}
           ]}
        end

      map = Topology.map(%{namespace: "d", rows: rows, runners: runners, plugins: plugins})

      assert length(map.bands) == 4
      assert length(map.zone.lanes) == 12
      assert length(map.sources) <= 10 and length(map.outputs) <= 10
      assert map.height < 3_600
    end

    test "lanes needing attention come first, then the busiest, then by id" do
      rows = [
        map_row("b_busy"),
        map_row("a_idle"),
        map_row("z_sick", %{health: :degraded}),
        map_row("c_busier")
      ]

      rates = %{
        "b_busy" => %{in: 5.0, out: 5.0},
        "c_busier" => %{in: 20.0, out: 1.0},
        "a_idle" => %{in: 0.0, out: 0.0}
      }

      map =
        Topology.map(%{namespace: "d", rows: rows, runners: [%{id: "runner-a"}], rates: rates})

      assert Enum.map(lanes(map), & &1.id) == ~w(z_sick c_busier b_busy a_idle)
    end

    test "no wire animates before two snapshots, and a moving lane carries its speed and rate" do
      rows = [map_row("orders")]
      first = Topology.map(%{namespace: "d", rows: rows, runners: [%{id: "runner-a"}]})

      refute first.animated?
      assert Enum.all?(first.wires, &(&1.bucket == :idle))
      assert hd(lanes(first)).rate == nil

      measured =
        Topology.map(%{
          namespace: "d",
          rows: rows,
          runners: [%{id: "runner-a"}],
          rates: %{"orders" => %{in: 12.0, out: 0.0}},
          history: %{"orders" => [%{in: 12.0, out: 0.0}, %{in: 4.0, out: 0.0}]}
        })

      assert measured.animated?
      assert Enum.find(measured.wires, &(&1.id == "calls->relay-orders")).bucket == :medium
      assert Enum.find(measured.wires, &(&1.id == "relay-orders->stream")).bucket == :idle
      assert %{rate: %{in: 12.0}, spark: spark} = hd(lanes(measured))
      assert is_binary(spark)
    end

    test "health is carried in words and shape, not colour alone" do
      map =
        Topology.map(%{
          namespace: "d",
          rows: [map_row("ok"), map_row("sick", %{health: :failed})],
          runners: [%{id: "runner-a"}]
        })

      [sick, ok] = lanes(map)
      assert {sick.state, sick.shape} == {"failed", "cross"}
      assert {ok.state, ok.shape} == {"healthy", "dot"}
    end

    test "parked entries open a drain to the dead-letter screen" do
      map = Topology.map(%{namespace: "d", rows: [], runners: [], parked: 3})

      assert %{sub: "3 parked", link: %{navigate: "/dlq"}} = map.drain
      assert Topology.map(%{namespace: "d", rows: [], runners: []}).drain == nil
    end

    test "the selection is marked on its lane, band or node" do
      map =
        Topology.map(%{
          namespace: "d",
          rows: [map_row("orders")],
          runners: [%{id: "runner-a"}],
          selected: {:relay, "orders"}
        })

      assert hd(lanes(map)).selected?
      refute hd(map.bands).selected?

      assert Topology.map(%{
               namespace: "d",
               rows: [],
               runners: [%{id: "runner-a"}],
               selected: {:runner, "runner-a"}
             }).bands
             |> hd()
             |> Map.fetch!(:selected?)
    end
  end
end
