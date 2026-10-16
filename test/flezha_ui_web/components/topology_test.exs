defmodule FlezhaUiWeb.TopologyTest do
  @moduledoc """
  The topology's arithmetic, its layout and its joins, without a controller.

  These are the cases a live stack cannot be asked to produce on demand — a
  counter reset, a first tick with no baseline, a relay bound to a runner
  the fleet has dropped, a graph shape no dev runner announces — and they are
  exactly the ones where a wrong answer would read as plausible on screen.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias FlezhaUiWeb.Topology

  @listener "Flezha.Plugin.Provider.MonitoredIOForward"
  @websocket "Flezha.Plugin.Provider.Websocket"

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
        bindings: [],
        sources: []
      },
      overrides
    )
  end

  defp binding(plugin_id, hook, position \\ nil, channel \\ nil) do
    %{
      plugin_id: plugin_id,
      hook: hook,
      provider: "Provider",
      position: position,
      channel: channel
    }
  end

  defp pipeline_input(overrides) do
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

  defp with_bindings(input, bindings), do: %{input | facts: %{input.facts | bindings: bindings}}

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
  defp ids(graph), do: Enum.map(graph.nodes, & &1.id)
  defp net(graph, id), do: Enum.find(graph.nets, &(&1.id == id))
  defp wires(graph), do: Enum.flat_map(graph.nets, & &1.wires)
  defp wire(graph, from, to), do: Enum.find(wires(graph), &(&1.from == from and &1.to == to))
  defp listener(id, hook), do: %{binding(id, hook) | provider: @listener}
  defp samples(values), do: Enum.map(values, &%{in: &1, out: &1, filtered: 0, parked: 0})

  defp points(wire) do
    wire.pts
    |> String.split(" ")
    |> Enum.map(fn pair -> pair |> String.split(",") |> Enum.map(&String.to_float/1) end)
  end

  defp channel(name, kind, producer, consumers, plugin_end \\ "none"),
    do: FakeController.graph_channel(name, kind, producer, consumers, plugin_end)

  defp tasklet(name, mode \\ "single", keys \\ []),
    do: %{name: name, mode: mode, cell_keys: keys, mailbox_capacity: 1024}

  defp announced(graph, factory \\ "market"),
    do: {:ok, %{relay: "relay_a", factory: factory, graph: graph, disagree: false, reason: nil}}

  defp source(id, entry),
    do: %{plugin_id: id, provider: @websocket, channel: List.wrap(entry)}

  defp bound(id, hook, position, channel),
    do: %{binding(id, hook, position, channel) | provider: "FlezhaKafka.Producer"}

  # `testnet_chain` as the dev runner announces it, fed by `ws_chain`, a
  # websocket source bound only to tear down and naming no channel.
  defp chain_graph do
    %{
      channels: [
        channel("input", "entry", nil, ~w(static_entry_tasklet)),
        channel("hop", "inter_tasklet", "static_entry_tasklet", ~w(static_downstream_tasklet)),
        channel("kafka", "plugin_bound", "static_downstream_tasklet", [], "output")
      ],
      tasklets: [
        tasklet("static_entry_tasklet", "static", ~w(a b c d)),
        tasklet("static_downstream_tasklet")
      ]
    }
  end

  defp chain(overrides \\ %{}) do
    pipeline_input(
      Map.merge(
        %{
          facts:
            facts(%{
              factory_id: "static_cell",
              bindings: [%{binding("ws_chain", "on_terminate") | provider: @websocket}],
              sources: [source("ws_chain", nil)]
            }),
          graph: announced(chain_graph(), "static_cell")
        },
        overrides
      )
    )
  end

  # The dev stack's `market` class as its runner announces it.
  defp market_graph do
    channels = [
      channel("trades_in", "entry", nil, ~w(route_latest ohlc sma ema rsi trades ticker_stats)),
      channel("book_in", "entry", nil, ~w(order_book)),
      channel("config_in", "entry", nil, ~w(route_latest)),
      channel("config_out", "inter_tasklet", "route_latest", ~w(price_signal volume_signal)),
      channel("ohlc_out", "inter_tasklet", "ohlc", ~w(adr atr volume_signal), "output"),
      channel("sma_out", "inter_tasklet", "sma", ~w(bollinger), "output"),
      channel("ema_out", "inter_tasklet", "ema", ~w(macd), "output"),
      channel("rsi_out", "plugin_bound", "rsi", [], "output"),
      channel("trades_out", "plugin_bound", "trades", [], "output"),
      channel("ticker_out", "inter_tasklet", "ticker_stats", ~w(price_signal), "output"),
      channel("book_out", "plugin_bound", "order_book", [], "output"),
      channel("adr_out", "plugin_bound", "adr", [], "output"),
      channel("atr_out", "plugin_bound", "atr", [], "output"),
      channel("macd_out", "plugin_bound", "macd", [], "output"),
      channel("boll_out", "plugin_bound", "bollinger", [], "output"),
      channel("price_signal_out", "plugin_bound", "price_signal", [], "output"),
      channel("volume_signal_out", "plugin_bound", "volume_signal", [], "output")
    ]

    tasklets =
      for name <- ~w(route_latest ohlc sma ema rsi trades ticker_stats order_book adr atr macd
                    bollinger price_signal volume_signal),
          do: tasklet(name, "dynamic")

    %{channels: channels, tasklets: tasklets}
  end

  defp market(overrides \\ %{}) do
    bindings = [
      bound("io_filter", "on_input", 0, nil),
      bound("demo_ohlc", "on_output", 0, ["ohlc_out"]),
      bound("demo_book", "on_output", 1, ["book_out"]),
      bound("demo_trades", "on_output", 2, ["trades_out"]),
      bound("demo_ticker", "on_output", 3, ["ticker_out"]),
      bound("demo_indicators", "on_output", 4, ~w(sma_out ema_out rsi_out macd_out boll_out)),
      bound("demo_events", "on_output", 5, ~w(price_signal_out volume_signal_out))
    ]

    sources = [source("trade_ws", "trades_in"), source("book_ws", "book_in")]

    pipeline_input(
      Map.merge(
        %{
          facts: facts(%{bindings: bindings, sources: sources}),
          graph: announced(market_graph())
        },
        overrides
      )
    )
  end

  # The dev runner's `showcase` factory, bound as the dev seed binds it.
  defp showcase_graph do
    channels = [
      channel("trades", "entry", nil, ~w(normalize_trade)),
      channel("quotes", "entry", nil, ~w(normalize_quote)),
      channel("normalize_trade", "inter_tasklet", "normalize_trade", ~w(merge_ticks)),
      channel("normalize_quote", "inter_tasklet", "normalize_quote", ~w(merge_ticks)),
      channel(
        "ticks",
        "inter_tasklet",
        "merge_ticks",
        ~w(price_by_symbol volume_window validate_tick audit_sample)
      ),
      channel("prices", "inter_tasklet", "price_by_symbol", ~w(detect_spike), "output"),
      channel("volumes", "inter_tasklet", "volume_window", ~w(detect_spike), "output"),
      channel("validate_tick", "inter_tasklet", "validate_tick", ~w(tag_venue)),
      channel("tag_venue", "inter_tasklet", "tag_venue", ~w(convert_currency)),
      channel("convert_currency", "inter_tasklet", "convert_currency", ~w(score_risk)),
      %{
        channel("quote", "plugin_bound", "score_risk", [], "call")
        | call_target: "factory:call_pricing"
      },
      channel("quote.response", "entry", nil, ~w(settle_order)),
      channel("orders", "plugin_bound", "settle_order", [], "output"),
      channel("alerts", "plugin_bound", "detect_spike", [], "output"),
      channel("audit", "plugin_bound", "audit_sample", [], "output")
    ]

    tasklets =
      [
        tasklet("normalize_trade"),
        tasklet("normalize_quote"),
        tasklet("merge_ticks"),
        tasklet("price_by_symbol", "dynamic"),
        tasklet("volume_window", "static", ~w(1m 5m 15m))
      ] ++
        Enum.map(
          ~w(validate_tick tag_venue convert_currency score_risk detect_spike settle_order audit_sample),
          &tasklet/1
        )

    %{channels: channels, tasklets: tasklets}
  end

  defp showcase(overrides \\ %{}) do
    file = fn id, position, channel ->
      %{
        binding(id, "on_output", position, [channel])
        | provider: "Flezha.Plugin.Provider.File.Sink"
      }
    end

    bindings = [
      %{binding("ws_trades", "on_terminate") | provider: @websocket},
      %{binding("skip_sells", "on_input", 0) | provider: "Flezha.Plugin.Provider.Filter"},
      file.("prices_file", 1, "prices"),
      file.("alerts_log", 2, "alerts"),
      file.("alerts_audit", 3, "alerts"),
      file.("orders_file", 4, "orders"),
      file.("audit_file", 5, "audit")
    ]

    sources = [
      source("ws_trades", "trades"),
      %{source("poll_quotes", "quotes") | provider: "Flezha.Plugin.Provider.HttpPoll"}
    ]

    pipeline_input(
      Map.merge(
        %{
          facts: facts(%{factory_id: "showcase", bindings: bindings, sources: sources}),
          graph: announced(showcase_graph(), "showcase")
        },
        overrides
      )
    )
  end

  defp activity(read_at, rows, instance \\ 1) do
    %{
      relay: "relay_a",
      runner: "runner-a",
      read_at_ms: read_at,
      instance_seq: instance,
      tasklets: rows
    }
  end

  # Where each node sits, to compare two drawings of one shape.
  defp places(graph), do: Map.new(graph.nodes, &{&1.id, {&1.x, &1.y, &1.w, &1.h}})

  # Two boxes overlap when they share more than a hairline.
  defp overlapping(graph) do
    boxes = for n <- graph.nodes, n.type not in [:entry, :exit], do: n

    for a <- boxes,
        b <- boxes,
        a.id < b.id,
        abs(a.x - b.x) < (a.w + b.w) / 2 - 1,
        abs(a.y - b.y) < (a.h + b.h) / 2 - 1,
        do: {a.id, b.id}
  end

  # The segments of each net that run across the drawn direction, in the gaps
  # between ranks: where its lanes are.
  defp lane_runs(graph) do
    across = if graph.direction == "LR", do: 0, else: 1

    for {net, p, q} <- segments(graph),
        abs(Enum.at(p, across) - Enum.at(q, across)) < 0.01,
        abs(Enum.at(p, 1 - across) - Enum.at(q, 1 - across)) > 0.01,
        uniq: true do
      {net, Enum.at(p, across), Enum.min([Enum.at(p, 1 - across), Enum.at(q, 1 - across)]),
       Enum.max([Enum.at(p, 1 - across), Enum.at(q, 1 - across)])}
    end
  end

  # Each drawn segment of every net, as `{net, p, q}`.
  defp segments(graph) do
    for n <- graph.nets,
        w <- n.wires,
        [p, q] <- w |> points() |> Enum.chunk_every(2, 1, :discard),
        do: {n.id, p, q}
  end

  defp lr(input), do: Map.put(input, :view, %{direction: "LR", width: nil, height: nil})
  defp tb(input), do: Map.put(input, :view, %{direction: "TB", width: nil, height: nil})

  describe "pipeline/1 shape" do
    test "a source bound only to tear down feeds the first entry, and no plumbing is drawn" do
      graph = Topology.pipeline(lr(chain()))

      assert ~w(source-ws_chain entry-input tasklet-static_entry_tasklet
                tasklet-static_downstream_tasklet exit-kafka unbound-kafka) -- ids(graph) == []

      refute Enum.any?(ids(graph), &(&1 in ~w(ingest channel output filtered)))
      refute Enum.any?(graph.nodes, &String.contains?(&1.id, "on_terminate"))
      assert wire(graph, "source-ws_chain", "entry-input")
      assert node(graph, "unbound-kafka").label == "no plugin bound"
      assert node(graph, "exit-kafka").unbound?
    end

    test "inside and outside line up: a source, its entry and the first tasklet share a line" do
      for {input, cross} <- [{lr(chain()), :y}, {tb(chain()), :x}] do
        graph = Topology.pipeline(input)

        lined =
          ~w(source-ws_chain entry-input tasklet-static_entry_tasklet tasklet-static_downstream_tasklet)
          |> Enum.map(&Map.fetch!(node(graph, &1), cross))
          |> Enum.uniq()

        assert length(lined) == 1, "#{graph.direction}: #{inspect(lined)}"
      end
    end

    test "the relay's own graph is drawn inside its boundary, plugins outside it" do
      graph = Topology.pipeline(lr(market()))
      box = graph.box
      inside? = &(&1.x > box.x and &1.x < box.x + box.w and &1.y > box.y and &1.y < box.y + box.h)

      assert Enum.count(graph.nodes, &(&1.type == :tasklet)) == 14
      assert graph.nodes |> Enum.filter(&(&1.type == :tasklet)) |> Enum.all?(inside?)
      refute graph.nodes |> Enum.filter(&(&1.type in [:plugin, :source])) |> Enum.any?(inside?)
      assert node(graph, "entry-trades_in").x == box.x
      assert node(graph, "exit-ohlc_out").x == box.x + box.w
      assert wire(graph, "tasklet-ohlc", "tasklet-atr")
      assert wire(graph, "tasklet-ohlc", "exit-ohlc_out")
      assert Enum.any?(graph.labels, &(&1.kind == :channel and &1.text == "ohlc_out"))
    end

    test "one plugin on several channels is drawn once, with a wire from each" do
      graph = Topology.pipeline(lr(market()))

      assert Enum.count(graph.nodes, &(&1.id == "plugin-demo_indicators")) == 1

      for ch <- ~w(sma_out ema_out rsi_out macd_out boll_out) do
        assert wire(graph, "exit-#{ch}", "plugin-demo_indicators"), ch
      end
    end

    test "an input filter stands between the sources of its entries and them, with its skipped end" do
      graph = Topology.pipeline(lr(market()))

      assert wire(graph, "source-trade_ws", "filter-io_filter")
      assert wire(graph, "filter-io_filter", "entry-trades_in")
      assert wire(graph, "filter-io_filter", "entry-book_in")
      assert node(graph, "skipped").label == "Skipped by filter"
      assert node(graph, "source-trade_ws").rank < node(graph, "filter-io_filter").rank
      assert node(graph, "filter-io_filter").rank < node(graph, "entry-trades_in").rank
    end

    test "with no filter bound the skipped end is drawn only once something was skipped" do
      quiet = Topology.pipeline(lr(chain()))

      skipped = %{
        relays: [%{relay_id: "relay_a", io_in_received: 5, forwarded: 3, filtered_nil: 2}]
      }

      graph = Topology.pipeline(lr(chain(%{snapshot: skipped})))

      refute node(quiet, "skipped")
      assert node(graph, "skipped").mark == "no filter bound"
      assert node(graph, "skipped").sub == "2 records"
    end

    test "the showcase: a fan-in, a fan-out, a folded run, a call and its answer, every output end" do
      graph = Topology.pipeline(lr(showcase()))

      run = node(graph, "run-validate_tick")
      assert run.label == "4 tasklets"
      assert run.sub == "validate_tick → score_risk"
      refute node(graph, "tasklet-tag_venue")
      assert wire(graph, "tasklet-merge_ticks", "run-validate_tick")
      assert wire(graph, "run-validate_tick", "exit-quote")
      assert wire(graph, "exit-quote", "call-quote")
      assert wire(graph, "answer-quote", "entry-quote.response")
      assert node(graph, "call-quote").label == "call_pricing"
      assert wire(graph, "exit-alerts", "plugin-alerts_log")
      assert wire(graph, "exit-alerts", "plugin-alerts_audit")
      assert wire(graph, "exit-volumes", "unbound-volumes")
      assert wire(graph, "tasklet-volume_window", "tasklet-detect_spike")
      assert wire(graph, "tasklet-volume_window", "exit-volumes")
      assert node(graph, "tasklet-volume_window").sub == "static · 1m, 5m, 15m"
      assert node(graph, "tasklet-volume_window").stacked?
      refute node(graph, "tasklet-merge_ticks").stacked?
      refute wire(graph, "filter-skip_sells", "entry-quote.response")
    end

    test "a folded run expands into its tasklets, and folds again" do
      expanded =
        Topology.pipeline(lr(showcase(%{expanded: MapSet.new(["run-validate_tick"])})))

      refute node(expanded, "run-validate_tick")

      for name <- ~w(validate_tick tag_venue convert_currency score_risk),
          do: assert(node(expanded, "tasklet-#{name}"), name)

      assert wire(expanded, "tasklet-validate_tick", "tasklet-tag_venue")
      assert expanded.expanded?
      refute Topology.pipeline(lr(showcase())).expanded?
    end

    test "names are whole up to 34 characters, and shortened in the middle past that" do
      long = "a_tasklet_name_that_runs_on_and_on_and_on"

      graph =
        Topology.pipeline(
          lr(
            pipeline_input(%{
              graph:
                announced(%{
                  channels: [channel("in", "entry", nil, [long, "static_downstream_tasklet"])],
                  tasklets: [tasklet(long), tasklet("static_downstream_tasklet")]
                })
            })
          )
        )

      assert node(graph, "tasklet-static_downstream_tasklet").label == "static_downstream_tasklet"
      assert %{label: label, full: ^long} = node(graph, "tasklet-#{long}")
      assert String.length(label) == 34
      assert label =~ "…"
    end

    test "a plugin naming a channel the relay lacks attaches to the relay, and says so" do
      input = market()
      bindings = [bound("typo", "on_output", 6, ["ohcl_out"]) | input.facts.bindings]

      graph =
        Topology.pipeline(lr(%{with_bindings(input, bindings) | selected: "plugin-typo"}))

      assert node(graph, "plugin-typo").mark == "no such channel"
      assert Enum.any?(wires(graph), &(&1.to == "plugin-typo" and &1.kind == :edge))
      assert graph.selected.plugin.missing == ["ohcl_out"]

      html = render_component(&Topology.pipeline_graph/1, topology: graph, tapped: nil)
      assert html =~ "The relay has no channel named"
    end

    test "an output plugin naming no channel is on the relay as a whole" do
      graph =
        Topology.pipeline(lr(with_bindings(chain(), [binding("all", "on_output", 0)])))

      assert node(graph, "plugin-all").mark == "every channel"
      refute wire(graph, "exit-kafka", "plugin-all")
    end

    test "without an announced graph the relay is an empty boundary between its sources and plugins" do
      bindings = [binding("out", "on_output", 0, ["x"])]

      graph =
        Topology.pipeline(
          lr(
            pipeline_input(%{
              facts: facts(%{bindings: bindings, sources: [source("ws", "input")]}),
              graph:
                {:ok, %{relay: "relay_a", factory: "store_input", graph: nil, disagree: false}}
            })
          )
        )

      assert graph.inside == {:not_announced, "store_input"}
      assert wire(graph, "source-ws", "inside")
      assert wire(graph, "inside", "plugin-out")
      refute Enum.any?(graph.nodes, &(&1.type in [:tasklet, :entry, :exit]))

      html = render_component(&Topology.pipeline_graph/1, topology: graph, tapped: nil)
      assert html =~ "announced no graph"
    end

    test "an empty announcement, or a channel from a tasklet the graph lacks, still draws" do
      empty =
        Topology.pipeline(lr(pipeline_input(%{graph: announced(%{channels: [], tasklets: []})})))

      assert empty.inside == {:not_announced, "market"}
      assert node(empty, "inside")

      ghost =
        Topology.pipeline(
          lr(
            pipeline_input(%{
              graph:
                announced(%{
                  channels: [
                    channel("in", "entry", nil, ~w(a)),
                    channel("out", "plugin_bound", "ghost", [], "output")
                  ],
                  tasklets: [tasklet("a")]
                })
            })
          )
        )

      assert node(ghost, "exit-out")
      refute Enum.any?(wires(ghost), &(&1.from == "tasklet-ghost"))
    end

    test "a plugin bound off the record path is listed with the relay, not drawn" do
      bindings = [binding("ticker", "on_interval"), binding("ticker", "on_terminate")]

      graph =
        Topology.pipeline(lr(with_bindings(chain(%{selected: "relay"}), bindings)))

      refute Enum.any?(ids(graph), &String.contains?(&1, "ticker"))
      assert [%{plugin_id: "ticker", hooks: hooks}] = graph.selected.lifecycle
      assert Enum.sort(hooks) == ~w(on_interval on_terminate)
    end

    test "every node id is unique, and the two directions give the same ranks and orders" do
      for input <- [chain(), market(), showcase()] do
        lr = Topology.pipeline(lr(input))
        tb = Topology.pipeline(tb(input))

        assert ids(lr) == Enum.uniq(ids(lr))

        assert Map.new(lr.nodes, &{&1.id, {&1.rank, &1.order}}) ==
                 Map.new(tb.nodes, &{&1.id, {&1.rank, &1.order}})

        assert overlapping(lr) == []
        assert overlapping(tb) == []
      end
    end

    test "no tick, selection, tap or open sheet moves a node" do
      base = Topology.pipeline(lr(market()))

      moved = [
        market(%{history: samples([3, 12, 900]), modes: %{in: :streaming}}),
        market(%{selected: "plugin-demo_ohlc"}),
        market(%{cells_of: "ohlc"}),
        market(%{
          activity:
            activity(10_000, [FakeController.activity_row("ohlc", %{queued_max: 40, cells: 312})]),
          prev_activity: activity(5_000, [FakeController.activity_row("ohlc", %{queued_max: 40})])
        })
      ]

      for input <- moved, do: assert(places(Topology.pipeline(lr(input))) == places(base))
    end

    test "Auto draws the direction the panel fits larger" do
      wide = %{direction: "auto", width: 1400, height: 640}
      narrow = %{direction: "auto", width: 390, height: 640}

      assert Topology.pipeline(Map.put(market(), :view, wide)).direction == "LR"
      assert Topology.pipeline(Map.put(chain(), :view, narrow)).direction == "TB"
    end

    test "a layout is placed once per shape and direction, and kept for the next tick" do
      first = Topology.pipeline(lr(market()))
      assert map_size(first.placed) == 1

      again = Topology.pipeline(lr(market(%{placed: first.placed, history: samples([4])})))
      assert again.placed == first.placed

      auto =
        Topology.pipeline(
          Map.put(market(%{placed: first.placed}), :view, %{
            direction: "auto",
            width: nil,
            height: nil
          })
        )

      assert map_size(auto.placed) == 2
    end
  end

  describe "pipeline/1 wires" do
    test "no two bending nets share a lane in a gap" do
      for input <- [lr(market()), tb(market()), lr(showcase()), tb(showcase())] do
        graph = Topology.pipeline(input)

        clashes =
          for {a, at, lo, hi} <- lane_runs(graph),
              {b, bt, blo, bhi} <- lane_runs(graph),
              a < b,
              abs(at - bt) < 1,
              lo < bhi - 0.5 and blo < hi - 0.5,
              do: {a, b, at}

        assert clashes == [], "#{graph.direction}: #{inspect(clashes)}"
      end
    end

    test "two entries into one tasklet arrive at different points, in different colours" do
      graph = Topology.pipeline(lr(market()))
      trades = wire(graph, "entry-trades_in", "tasklet-route_latest")
      config = wire(graph, "entry-config_in", "tasklet-route_latest")

      assert List.last(points(trades)) != List.last(points(config))

      assert net(graph, "entry-trades_in|trades_in").colour !=
               net(graph, "entry-config_in|config_in").colour
    end

    test "a seven-way fan-out is one net that splits, with a junction at each split" do
      graph = Topology.pipeline(lr(market()))
      fan = net(graph, "entry-trades_in|trades_in")

      assert length(fan.wires) == 7
      assert length(fan.junctions) == 6

      assert MapSet.new(fan.ends) ==
               MapSet.new(
                 ~w(entry-trades_in tasklet-route_latest tasklet-ohlc tasklet-sma tasklet-ema tasklet-rsi tasklet-trades tasklet-ticker_stats)
               )
    end

    test "nets into one node never share a colour, of six" do
      for input <- [lr(market()), lr(showcase()), tb(showcase())] do
        graph = Topology.pipeline(input)
        colour = Map.new(graph.nets, &{&1.id, &1.colour})

        assert graph.nets
               |> Enum.map(& &1.colour)
               |> Enum.reject(&is_nil/1)
               |> Enum.all?(&(&1 in 0..5))

        into =
          graph
          |> wires()
          |> Enum.group_by(& &1.to)
          |> Enum.map(fn {_to, ws} -> ws |> Enum.map(&net_of(graph, &1)) |> Enum.uniq() end)

        for nets <- into, a <- nets, b <- nets, a < b, colour[a] && colour[b] do
          assert colour[a] != colour[b], "#{a} and #{b} meet in #{graph.direction}"
        end
      end
    end

    test "a channel keeps its colour through its port" do
      for input <- [lr(market()), tb(market()), lr(showcase()), tb(showcase())] do
        graph = Topology.pipeline(input)
        colour = Map.new(graph.nets, &{&1.id, &1.colour})
        ws = wires(graph)

        for {port, into} <- Enum.group_by(ws, & &1.to),
            String.starts_with?(port, ["entry-", "exit-"]),
            [arriving] <- [into |> Enum.map(&net_of(graph, &1)) |> Enum.uniq()],
            leaving = Enum.find(ws, &(&1.from == port)) do
          assert colour[arriving] == colour[net_of(graph, leaving)],
                 "#{port} changes colour in #{graph.direction}"
        end
      end

      graph = Topology.pipeline(lr(market()))

      assert net(graph, "tasklet-bollinger|boll_out").colour ==
               net(graph, "exit-boll_out|boll_out").colour

      assert net(graph, "tasklet-sma|sma_out").colour !=
               net(graph, "tasklet-bollinger|boll_out").colour
    end

    test "top to bottom, no lane runs through a channel's name or its rate below it" do
      for input <- [tb(market()), tb(showcase())] do
        graph = Topology.pipeline(input)

        for l <- graph.labels, l.kind == :channel do
          right = l.x + max(String.length(l.text), 7) * 6.3

          hits =
            for {_net, y, a, b} <- lane_runs(graph),
                y > l.y - 9 and y < l.y + 14,
                a < right and b > l.x,
                do: y

          assert hits == [], "a lane crosses #{l.text} at #{inspect(hits)}"
        end
      end
    end

    test "two sources into one entry keep apart in colour" do
      sources = [source("ws1", "input"), source("ws2", "input")]
      bindings = for id <- ~w(ws1 ws2), do: %{binding(id, "on_terminate") | provider: @websocket}

      input =
        chain(%{
          facts: facts(%{factory_id: "static_cell", bindings: bindings, sources: sources})
        })

      for input <- [lr(input), tb(input)] do
        graph = Topology.pipeline(input)

        assert net(graph, "source-ws1|input").colour != net(graph, "source-ws2|input").colour,
               graph.direction
      end
    end

    test "lanes are ordered to cross as few nets as they can" do
      for {input, most} <- [
            {lr(market()), 7},
            {tb(market()), 7},
            {lr(showcase()), 0},
            {tb(showcase()), 0}
          ] do
        graph = Topology.pipeline(input)
        assert crossings(graph) <= most, "#{graph.direction}: #{crossings(graph)} crossings"
      end
    end

    test "a wire passing a rank keeps its line through it, and bends only beyond it" do
      graph = Topology.pipeline(tb(showcase()))
      spike = node(graph, "tasklet-detect_spike")
      volumes = graph |> wire("tasklet-volume_window", "exit-volumes") |> points()

      bends = for [[x0, y], [x1, y]] <- Enum.chunk_every(volumes, 2, 1, :discard), x0 != x1, do: y
      assert bends != []
      assert Enum.all?(bends, &(&1 > spike.y + spike.h / 2)), inspect(volumes)
    end

    test "neighbours in a rank keep their gap, whatever lines up with what" do
      for input <- [
            lr(chain()),
            tb(chain()),
            lr(market()),
            tb(market()),
            lr(showcase()),
            tb(showcase())
          ] do
        graph = Topology.pipeline(input)
        {cross, size} = if graph.direction == "LR", do: {:y, :h}, else: {:x, :w}

        for {_rank, row} <-
              Enum.group_by(Enum.reject(graph.nodes, &(&1.type in [:entry, :exit])), & &1.rank),
            [a, b] <-
              row |> Enum.sort_by(&Map.fetch!(&1, cross)) |> Enum.chunk_every(2, 1, :discard) do
          gap =
            Map.fetch!(b, cross) - Map.fetch!(b, size) / 2 -
              (Map.fetch!(a, cross) + Map.fetch!(a, size) / 2)

          assert gap >= 15.9, "#{graph.direction}: #{a.id} and #{b.id} are #{gap} apart"
        end
      end
    end

    test "every wire leaves and arrives at right angles, from the drawn polyline" do
      graph = Topology.pipeline(tb(showcase()))

      for w <- wires(graph),
          [[x0, y0], [x1, y1]] <- w |> points() |> Enum.chunk_every(2, 1, :discard) do
        assert abs(x0 - x1) < 0.01 or abs(y0 - y1) < 0.01, inspect({w.id, x0, y0, x1, y1})
      end
    end
  end

  # Where a segment running across the drawn direction meets one running
  # along it, of another net.
  defp crossings(graph) do
    segs = segments(graph)

    Enum.count(
      for {a, [ax0, ay0], [ax1, ay1]} <- segs,
          {b, [bx0, by0], [bx1, by1]} <- segs,
          a != b,
          abs(ax0 - ax1) < 0.01 and abs(by0 - by1) < 0.01 and bx0 != bx1 and ay0 != ay1,
          ax0 > min(bx0, bx1) + 0.5 and ax0 < max(bx0, bx1) - 0.5,
          by0 > min(ay0, ay1) + 0.5 and by0 < max(ay0, ay1) - 0.5,
          do: 1
    )
  end

  defp net_of(graph, wire), do: Enum.find_value(graph.nets, &(wire in &1.wires && &1.id))

  describe "pipeline/1 observers" do
    test "listeners are counted at the edge they watch, drawn as no node, and move nothing" do
      base = Topology.pipeline(lr(chain()))
      input = chain()

      listened =
        input.facts.bindings ++
          [
            listener("io_listener_in", "on_input"),
            listener("io_listener_out", "on_output"),
            listener("io_listener_out", "on_preview"),
            listener("io_listener_calls", "on_call")
          ]

      graph = Topology.pipeline(lr(with_bindings(input, listened)))

      assert places(graph) == places(base)
      assert graph.edges.in.ids == ["io_listener_in"]
      assert graph.edges.out.ids == ["io_listener_out"]
      assert graph.edges.calls.ids == ["io_listener_calls"]
      assert graph.observer_count == 3
      refute Enum.any?(ids(graph), &String.contains?(&1, "io_listener"))
    end

    test "a tally hears no record, so it is no listener" do
      input = chain()

      tally =
        %{listener("io_listener_tally", "on_output") | position: 0} |> Map.put(:tally?, true)

      graph =
        Topology.pipeline(lr(with_bindings(input, [tally | input.facts.bindings])))

      assert graph.observer_count == 0
      assert graph.edges.out.ids == []

      html = render_component(&Topology.pipeline_graph/1, topology: graph, tapped: nil)
      refute html =~ "topology-observer-count"
    end

    test "the header counts plugins once, and listeners apart" do
      bindings = [
        binding("fan", "on_output", 0, ["kafka"]),
        binding("fan", "on_terminate"),
        listener("io_listener_out", "on_output")
      ]

      graph = Topology.pipeline(lr(with_bindings(chain(), bindings)))
      html = render_component(&Topology.pipeline_graph/1, topology: graph, tapped: nil)

      assert graph.plugin_count == 1
      assert graph.observer_count == 1
      assert html =~ ~r/1 plugin attached<span[^>]*> · 1 listening/
    end
  end

  describe "pipeline/1 rates and recency" do
    test "an entry wire reads IN as the mean of the newest seven samples, and when a record last came" do
      history =
        Enum.map(
          [100, 0, 0, 7, 0, 0, 7, 0, 0],
          &%{"entry-input" => &1, in: &1, out: &1, filtered: 0, parked: 0}
        )

      graph =
        Topology.pipeline(
          lr(
            chain(%{
              history: history,
              now: 100_000,
              opened_at: 0,
              seen: %{"entry-input" => 96_000},
              modes: %{"entry-input" => :trickling}
            })
          )
        )

      label = Enum.find(graph.labels, &(&1.kind == :in))
      # 0+7+0+0+7+0+0 over seven: the burst nine ticks ago has left the window.
      assert label.text == "IN 2.0/s"
      assert label.more == "~4 s ago"
      assert label.testid == "topo-rate-in-input"
    end

    test "with no baseline no wire reads a rate, and a quiet entry says for how long" do
      graph = Topology.pipeline(lr(chain()))
      assert Enum.find(graph.labels, &(&1.kind == :in)).text == "IN"

      quiet =
        Topology.pipeline(
          lr(
            chain(%{
              history: [%{"entry-input" => 0, in: 0, out: 0}],
              now: 100_000,
              opened_at: 0,
              seen: %{"entry-input" => 20_000},
              modes: %{"entry-input" => :quiet}
            })
          )
        )

      assert Enum.find(quiet.labels, &(&1.kind == :in)).more == "quiet for 1m 20s"
      assert Topology.rate_label(0.04) == "<0.1 msgs/s"
      assert Topology.rate_label(nil) == nil
    end

    test "each output channel reads its own rate" do
      history = [%{"exit-alerts" => 2.0, "exit-orders" => 0.4, in: 0, out: 0}]
      graph = Topology.pipeline(lr(showcase(%{history: history})))
      out = Map.new(for(l <- graph.labels, l.kind == :out, do: {l.ch, l.text}))

      assert out["alerts"] == "OUT 2.0/s"
      assert out["orders"] == "OUT 0.4/s"
    end

    test "a wire's tooltip names its channel, its rate and its last record, or says it is not counted" do
      history = [%{"tasklet-static_downstream_tasklet" => 1.5, in: 1, out: 1}]

      graph =
        Topology.pipeline(
          lr(
            chain(%{
              history: history,
              now: 10_000,
              seen: %{"tasklet-static_downstream_tasklet" => 7_000}
            })
          )
        )

      assert wire(graph, "tasklet-static_entry_tasklet", "tasklet-static_downstream_tasklet").title ==
               "hop: 1.5/s, last record ~3 s ago"

      bindings = [binding("a", "on_input", 0, ["input"]), binding("b", "on_input", 1, ["input"])]
      filtered = Topology.pipeline(lr(with_bindings(chain(), bindings)))
      assert wire(filtered, "filter-a", "filter-b").title == "input: not counted"
    end

    test "a stall verdict on the relay, its runner or its channel marks the boundary" do
      assert Topology.pipeline(lr(chain(%{verdicts: [%{layer: :x, subject: "relay_a"}]}))).stalled?

      assert Topology.pipeline(lr(chain(%{verdicts: [%{layer: :x, subject: "runner-a"}]}))).stalled?

      refute Topology.pipeline(lr(chain(%{verdicts: [%{layer: :x, subject: "other"}]}))).stalled?

      verdicts = [
        %{layer: :relay_not_forwarding, subject: "relay_a"},
        %{layer: :older, subject: nil}
      ]

      assert Topology.pipeline(lr(chain(%{verdicts: verdicts}))).stall.layer ==
               :relay_not_forwarding
    end

    test "a runner channel out of credit reads Stuck and marks the output edge" do
      snapshot = %{
        relays: [%{relay_id: "relay_a", io_in_received: 1, forwarded: 1}],
        channels: [
          %{name: "runner-a", runner_id: "runner-a", credit_active: 1, credit_ledger_level: 0}
        ]
      }

      graph = Topology.pipeline(lr(chain(%{snapshot: snapshot, selected: "relay"})))

      assert graph.backpressure?
      assert graph.edges.backpressure
      assert graph.flow.word == :stuck
      assert graph.selected.channel.credit_active == 1
    end
  end

  describe "wire_mode/3" do
    # {from, rate, ms since a record passed, to}: streaming starts at 12/s and
    # holds until 9/s; trickling holds while a record passed within 30 s.
    for {from, rate, since, to} <- [
          {:trickling, 12.0, 0, :streaming},
          {:trickling, 11.0, 0, :trickling},
          {:streaming, 10.0, 0, :streaming},
          {:streaming, 9.0, 0, :trickling},
          {:quiet, 0.1, 30_000, :trickling},
          {:trickling, 0.1, 30_001, :quiet},
          {:quiet, nil, nil, :quiet}
        ] do
      test "#{from} at #{inspect(rate)}/s, #{inspect(since)} ms since a record, is #{to}" do
        assert Topology.wire_mode(unquote(from), unquote(rate), unquote(since)) == unquote(to)
      end
    end
  end

  describe "tasklet figures" do
    test "a rate is the advance of admitted_total over the advance of read_at_ms" do
      before = activity(1_000, [FakeController.activity_row("ohlc", %{admitted_total: 100})])
      now = activity(11_000, [FakeController.activity_row("ohlc", %{admitted_total: 150})])

      assert Topology.tasklet_rates(now, before) == %{{:tasklet, "ohlc"} => 5.0}
    end

    test "a falling counter clamps to zero, and another instance gives no rate" do
      before = activity(1_000, [FakeController.activity_row("ohlc", %{admitted_total: 150})])
      fell = activity(2_000, [FakeController.activity_row("ohlc", %{admitted_total: 100})])
      other = activity(2_000, [FakeController.activity_row("ohlc", %{admitted_total: 400})], 2)

      assert Topology.tasklet_rates(fell, before) == %{{:tasklet, "ohlc"} => 0.0}
      assert Topology.tasklet_rates(other, before) == %{}
    end

    test "the rate sits in the tasklet's slot without resizing it" do
      quiet = Topology.pipeline(lr(market()))
      history = [%{{:tasklet, "ohlc"} => 312.4, in: 0, out: 0}]

      graph =
        Topology.pipeline(
          lr(
            market(%{
              history: history,
              activity: activity(2, [FakeController.activity_row("ohlc")])
            })
          )
        )

      assert node(graph, "tasklet-ohlc").rate == "312.4/s"
      assert node(graph, "tasklet-ohlc").w == node(quiet, "tasklet-ohlc").w
      assert node(quiet, "tasklet-ohlc").rate == nil
    end

    test "a queue held over two readings is a backlog badge, what it dropped is shed, its dead letters too" do
      row = &FakeController.activity_row("order_book", &1)

      graph =
        Topology.pipeline(
          lr(
            market(%{
              activity: activity(2_000, [row.(%{queued_max: 40, dropped_oldest_total: 8})]),
              prev_activity: activity(1_000, [row.(%{queued_max: 12, dropped_oldest_total: 5})]),
              parked_by: %{"order_book" => 2}
            })
          )
        )

      assert node(graph, "tasklet-order_book").badges == [
               {:parked, "2 dead letters"},
               {:backlog, "40 queued"},
               {:shed, "3 shed"}
             ]

      once =
        Topology.pipeline(lr(market(%{activity: activity(2_000, [row.(%{queued_max: 40})])})))

      assert node(once, "tasklet-order_book").badges == []
    end

    test "a dynamic tasklet's caption carries its live Cell count" do
      graph =
        Topology.pipeline(
          lr(
            market(%{activity: activity(2, [FakeController.activity_row("ohlc", %{cells: 342})])})
          )
        )

      assert node(graph, "tasklet-ohlc").sub == "dynamic · 342 Cells"
      assert node(Topology.pipeline(lr(market())), "tasklet-ohlc").sub == "dynamic · Cells"
    end
  end

  describe "the Cell sheet" do
    defp cells_read(read_at, rows, total \\ nil) do
      activity(read_at, [FakeController.activity_row("static_entry_tasklet", %{cells: 4})])
      |> Map.merge(%{
        cells_asked: "static_entry_tasklet",
        cells: %{tasklet: "static_entry_tasklet", cells_total: total || length(rows), rows: rows}
      })
    end

    defp cells_of(input),
      do: Topology.pipeline(lr(Map.put(input, :cells_of, "static_entry_tasklet"))).cells

    test "lists the tasklet's Cells, their intake between reads, and which took a record since" do
      cell = &FakeController.cell_row/2

      before =
        cells_read(1_000, [cell.("a", %{admitted_total: 10}), cell.("b", %{admitted_total: 4})])

      now =
        cells_read(3_000, [
          cell.("a", %{admitted_total: 30, queued: 2, last_admitted_ms: 2_900}),
          cell.("b", %{admitted_total: 4, blocked_total: 1, last_admitted_ms: 500}),
          cell.("c", %{last_admitted_ms: 0})
        ])

      previous = Map.merge(before.cells, %{read_at_ms: 1_000, instance: {"runner-a", 1}})
      sheet = cells_of(chain(%{activity: now, prev_cells: previous}))

      assert [%{key: "a", rate: 10.0, queued: 2, fresh?: true, ago_ms: 100}, b, c] = sheet.rows
      assert %{key: "b", rate: +0.0, blocked: 1, fresh?: false, ago_ms: 2_500} = b
      assert %{key: "c", rate: nil, ago_ms: nil} = c

      assert sheet.hops == [
               %{label: "hop → static_downstream_tasklet", tasklet: "static_downstream_tasklet"}
             ]

      assert sheet.caption == "static · a, b, c, d"
    end

    test "sorts by any column, the busiest first by default" do
      cell = &FakeController.cell_row/2

      rows = [
        cell.("b", %{queued: 1, last_admitted_ms: 900}),
        cell.("a", %{queued: 5, last_admitted_ms: 100}),
        cell.("c", %{queued: 3, last_admitted_ms: 500})
      ]

      input = chain(%{activity: cells_read(1_000, rows)})
      keys = &Enum.map(cells_of(Map.put(input, :cells_sort, &1)).rows, fn r -> r.key end)

      assert keys.("key") == ~w(a b c)
      assert keys.("queued") == ~w(a c b)
      assert keys.("ago") == ~w(b c a)
    end

    test "says how many it shows of how many, and when the runner reports none" do
      many = chain(%{activity: cells_read(1_000, [FakeController.cell_row("a")], 342)})
      sheet = cells_of(many)

      html =
        render_component(&Topology.pipeline_graph/1,
          topology: Topology.pipeline(lr(Map.put(many, :cells_of, "static_entry_tasklet"))),
          tapped: nil
        )

      assert sheet.total == 342
      assert html =~ "Showing the 1 most recently active of 342 Cells."

      none = %{cells_read(1_000, []) | cells: nil}
      assert cells_of(chain(%{activity: none})).note == :not_reported
    end
  end

  describe "pipeline/1 state and timeline" do
    defp word(history, mode),
      do: Topology.pipeline(lr(chain(%{history: history, modes: %{in: mode, out: mode}}))).flow

    test "a moving relay reads by its input's state, with its figures" do
      history = Enum.map(1..7, fn _ -> %{in: 120.0, out: 108.0, filtered: 12.0, parked: 0} end)

      assert %{word: :streaming, sentence: sentence} = word(history, :streaming)
      assert sentence =~ "120.0 msgs/s in"
      assert sentence =~ "108.0 msgs/s delivered"
      assert sentence =~ "10% skipped by its input filters"
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

      timeline = Topology.pipeline(lr(chain(%{history: history}))).timeline
      rows = Map.new(timeline.rows, &{&1.key, &1.bars})

      assert timeline.samples == 2
      assert [%{x: x_in}] = rows.in
      assert [%{x: x_parked}] = rows.parked
      assert length(rows.out) == 1 and length(rows.filtered) == 1
      assert x_parked > x_in
      assert x_parked + 10 == timeline.width
    end
  end

  describe "pipeline_graph/1" do
    test "draws the boundary, each net with its geometry, the tapped port and the inspector" do
      graph = Topology.pipeline(lr(chain(%{selected: "source-ws_chain"})))
      html = render_component(&Topology.pipeline_graph/1, topology: graph, tapped: "entry-input")
      doc = LazyHTML.from_fragment(html)

      hop =
        LazyHTML.query(
          doc,
          ~s([data-wire="tasklet-static_entry_tasklet>tasklet-static_downstream_tasklet>hop"])
        )

      assert html =~ "factory static_cell"
      assert [pts] = LazyHTML.attribute(hop, "data-pts")
      assert length(String.split(pts)) >= 2

      assert LazyHTML.attribute(
               LazyHTML.query(doc, ~s([data-testid="topo-node-entry-input"])),
               "aria-pressed"
             ) == ["true"]

      assert html =~ ~s(data-testid="topo-tapping-entry-input")

      assert html =~
               "Its options name no channel, so it feeds the relay&#39;s first entry channel, input."

      assert html =~ "on_terminate"
      assert LazyHTML.query(doc, ".flz-graph-node--plugin") |> Enum.count() >= 1
      assert LazyHTML.query(doc, "#topology-svg .flz-graph-node--tasklet") |> Enum.count() == 2
    end

    test "the legend names every role, mark and motion form" do
      html =
        render_component(&Topology.pipeline_graph/1,
          topology: Topology.pipeline(lr(chain())),
          tapped: nil
        )

      legend =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-testid="topology-legend"]))
        |> LazyHTML.text()

      for words <- [
            "dashed edge",
            "several Cells",
            "folded run",
            "a source",
            "input filter",
            "skipped",
            "no plugin bound",
            "channel splits",
            "its speed is not the record",
            "twelve or more",
            "Dead letters",
            "backlog"
          ] do
        assert legend =~ words, words
      end
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

    test "a controller that counts bytes gives byte rates too; one that does not gives none" do
      with_bytes = &Map.merge(counters("relay_a", &1, &1), %{bytes_in: &2, bytes_forwarded: &2})
      previous = snapshot([with_bytes.(100, 10_000)])
      current = snapshot([with_bytes.(140, 14_096)])

      assert %{"relay_a" => %{in: 20.0, bytes_in: 2048.0, bytes_out: 2048.0} = rate} =
               Topology.rates(current, previous, 2_000)

      assert Topology.traffic_label(rate, :in) == "20.0 msgs/s · 2.0 KB/s"

      older =
        Topology.rates(
          snapshot([counters("relay_a", 140, 120)]),
          snapshot([counters("relay_a", 100, 90)]),
          2_000
        )

      refute Map.has_key?(older["relay_a"], :bytes_in)
      assert Topology.traffic_label(older["relay_a"], :in) == "20.0 msgs/s"
    end

    # {why, current received, previous received, elapsed ms}; nil is no snapshot.
    for {why, current, previous, elapsed} <- [
          {"a first snapshot has no baseline", 100, nil, 2_000},
          {"a missing snapshot has nothing to advance", nil, 1, 2_000},
          {"no elapsed time is not divided by", 140, 100, 0}
        ] do
      test "#{why}, so it yields no rates" do
        reading = &(&1 && snapshot([counters("relay_a", &1, &1)]))

        assert Topology.rates(
                 reading.(unquote(current)),
                 reading.(unquote(previous)),
                 unquote(elapsed)
               ) ==
                 %{}
      end
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
    # {samples held, samples after the push}: newest first, capped at sixty.
    for {held, after_push} <- [{1, 2}, {59, 60}, {60, 60}] do
      test "#{held} held samples become #{after_push}, the newest first" do
        held = Enum.map(1..unquote(held), &%{in: &1 * 1.0, out: 0.0})

        history =
          Topology.push_history(%{"relay_a" => held}, %{"relay_a" => %{in: 99.0, out: 0.0}})

        assert length(history["relay_a"]) == unquote(after_push)
        assert [%{in: 99.0}, %{in: 1.0} | _rest] = history["relay_a"]
      end
    end
  end

  describe "speed_bucket/1" do
    # Each bucket ends where the next begins; no rate and no flow are idle.
    for {rate, bucket} <- [
          {nil, :idle},
          {+0.0, :idle},
          {0.1, :slow},
          {9.9, :slow},
          {10.0, :medium},
          {99.9, :medium},
          {100.0, :fast}
        ] do
      test "#{inspect(rate)} msgs/s is #{bucket}" do
        assert Topology.speed_bucket(unquote(rate)) == unquote(bucket)
      end
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

    test "a lane states its rate in messages and, when counted, bytes; a stack sums both" do
      rows = [map_row("solo")] ++ for(i <- 1..4, do: map_row("s_#{i}", %{factory: "same"}))
      rate = %{in: 4.0, out: 4.0, bytes_in: 2048.0, bytes_out: 1024.0}
      rates = Map.new(["solo", "s_1", "s_2", "s_3", "s_4"], &{&1, rate})

      map =
        Topology.map(%{namespace: "d", rows: rows, runners: [%{id: "runner-a"}], rates: rates})

      html = render_component(&Topology.namespace_map/1, map: map)

      assert html =~ ~r/data-testid="map-rate-solo".*?4.0 msgs\/s.*?2.0 KB\/s/s
      assert %{in: 16.0, bytes_in: 8192.0} = Enum.find(lanes(map), &(&1.kind == :stack)).rate
      assert html =~ "Rates are messages a second, then bytes"
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
