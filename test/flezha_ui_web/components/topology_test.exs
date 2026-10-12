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
        rate: nil,
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

  defp chain(graph), do: Enum.map(graph.nodes, & &1.kind)
  defp node(graph, id), do: Enum.find(graph.nodes, &(&1.id == id))
  defp edge(graph, id), do: Enum.find(graph.edges, &(&1.id == id))

  describe "pipeline/1 structure" do
    test "a relay with nothing bound is still a full chain, ending in its output" do
      graph = Topology.pipeline(pipeline_input())

      assert chain(graph) == [:ingest, :core, :channel, :output]
      assert graph.plugin_count == 0
    end

    test "input and output plugins sit on the record path, in position order" do
      bindings = [
        binding("late_out", "on_output", 1),
        binding("early_in", "on_input", 0),
        binding("early_out", "on_output", 0)
      ]

      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{bindings: bindings})}))

      assert chain(graph) == [:ingest, :plugin, :core, :plugin, :plugin, :channel, :output]

      assert Enum.map(graph.nodes, & &1.label) == [
               "Ingest",
               "early_in",
               "relay_a",
               "early_out",
               "late_out",
               "runner-a",
               "Output"
             ]
    end

    test "a hook that is not on the record path hangs off the core instead" do
      bindings = [binding("ticker", "on_interval"), binding("feeder", "on_input", 0)]

      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{bindings: bindings})}))

      # The chain carries only the inbound plugin...
      assert chain(graph) == [:ingest, :plugin, :core, :channel, :output, :plugin]
      # ...and the off-path one is joined by a satellite edge, not a flow edge.
      assert edge(graph, "branch-plugin-ticker").kind == :satellite
      refute edge(graph, "flow-plugin-ticker-relay_a")
    end

    test "the chain is drawn top to bottom, each node one row below the last" do
      graph = Topology.pipeline(pipeline_input())

      ys = Enum.map(graph.nodes, & &1.y)

      assert ys == Enum.sort(ys)
      assert Enum.uniq(Enum.map(graph.nodes, & &1.x)) == [Enum.at(graph.nodes, 0).x]
    end

    test "a relay bound to no runner reports an unbound channel and a degraded edge" do
      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{runner_id: nil})}))

      assert node(graph, "channel").state == :unbound
      assert node(graph, "channel").label == "unbound"
      assert edge(graph, "flow-relay_a-channel").degraded?
    end

    test "parked entries draw a dead-letter branch carrying the count" do
      graph = Topology.pipeline(pipeline_input(%{parked: 4}))

      assert node(graph, "dead-letter").sub == "4 parked"
      assert edge(graph, "branch-dead-letter").kind == :dlq
    end

    test "nothing parked means no dead-letter branch" do
      graph = Topology.pipeline(pipeline_input())

      refute node(graph, "dead-letter")
    end

    test "a suspended relay is styled apart" do
      graph = Topology.pipeline(pipeline_input(%{facts: facts(%{suspended: true})}))

      assert node(graph, "relay_a").state == :suspended
    end

    test "a channel whose credit ran dry reports backpressure" do
      snapshot = %{
        channels: [
          %{runner_id: "runner-a", name: :chan_a, credit_active: 1, credit_ledger_level: 0}
        ],
        relays: []
      }

      graph = Topology.pipeline(pipeline_input(%{snapshot: snapshot}))

      assert node(graph, "channel").backpressure?
      assert node(graph, "channel").channel.name == "chan_a"
    end
  end

  describe "pipeline/1 rates" do
    test "rates land only on the edges the controller counts" do
      bindings = [binding("in_1", "on_input", 0), binding("out_1", "on_output", 0)]

      graph =
        Topology.pipeline(
          pipeline_input(%{
            facts: facts(%{bindings: bindings}),
            rate: %{in: 12.0, out: 9.0}
          })
        )

      # Into the relay, and out of it.
      assert edge(graph, "flow-plugin-in_1-relay_a").rate == 12.0
      assert edge(graph, "flow-relay_a-plugin-out_1").rate == 9.0
      # Ingest to the first plugin, and plugin to channel, are not counted.
      assert edge(graph, "flow-ingest-plugin-in_1").rate == nil
      assert edge(graph, "flow-plugin-out_1-channel").rate == nil
    end

    test "an idle rate still renders, in the idle bucket" do
      graph = Topology.pipeline(pipeline_input(%{rate: %{in: +0.0, out: +0.0}}))

      assert edge(graph, "flow-ingest-relay_a").bucket == :idle
    end

    test "no baseline means no figure anywhere" do
      graph = Topology.pipeline(pipeline_input())

      assert Enum.all?(graph.edges, &is_nil(&1.rate))
    end
  end

  describe "pipeline/1 selection and stalls" do
    test "a selected node is resolved to the node itself" do
      graph = Topology.pipeline(pipeline_input(%{selected: "relay_a"}))

      assert graph.selected.kind == :core
    end

    test "a node that cannot be selected is not selected" do
      graph = Topology.pipeline(pipeline_input(%{selected: "ingest"}))

      refute graph.selected
    end

    test "a selected relay's sparkline draws from a single idle sample" do
      graph =
        Topology.pipeline(pipeline_input(%{selected: "relay_a", history: [%{in: 0, out: 0}]}))

      html = render_component(&Topology.pipeline_graph/1, topology: graph)

      assert html =~ ~s(data-testid="topology-sparkline")
      assert html =~ ~s(points="0.0,39.0")
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

    defp counters(id, received, forwarded) do
      %{relay_id: id, io_in_received: received, forwarded: forwarded, filtered_nil: 0}
    end

    test "advancing counters over elapsed time become messages per second" do
      previous = snapshot([counters("relay_a", 100, 90)])
      current = snapshot([counters("relay_a", 140, 120)])

      assert %{"relay_a" => %{in: 20.0, out: 15.0}} = Topology.rates(current, previous, 2_000)
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

      assert Enum.map(map.sources, & &1.id) == ["calls", "in-ws_in"]
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

      assert %{sub: "3 parked", href: "/dlq"} = map.drain
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
