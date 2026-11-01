defmodule FlezhaConsoleWeb.RelayCallActivityTest do
  @moduledoc """
  The relay screen's Calls panel: a listen on the relay's calls, held while the
  panel is open, pairing each call with its outcome by call id.

  The events are driven in the shapes core's `Relay.listen/5` hands on for the
  `:calls` direction, including the retries, refusals and stray outcomes a
  live relay will not produce on demand.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Relay

  @url "/namespaces/default/relays/relay_a"
  @listen {Relay, :listen}

  setup %{node: node} do
    FakeController.set(node, {Relay, :overwatch_state}, {:ok, %{factory_id: "orders"}})

    FakeController.set(
      node,
      {Relay, :list},
      FakeController.rows([FakeController.relay_row("relay_a")])
    )

    :ok
  end

  defp open_calls(conn, node) do
    {:ok, view, _html} = live(conn, @url)
    open_section(view, "calls")
    assert FakeController.eventually(fn -> FakeController.streams(node, @listen) != [] end)
    assert shows?(view, ~s(data-testid="calls-listening"))
    view
  end

  defp call(node, id, opts \\ []) do
    meta =
      Map.merge(
        %{
          "flz.call_id" => id,
          "flz.call_source" => Keyword.get(opts, :source, "cli"),
          "channel" => Keyword.get(opts, :channel, "place"),
          "flz.call_at" => 1_760_000_000_000
        },
        Keyword.get(opts, :meta, %{})
      )

    FakeController.emit(node, @listen, {:call, Keyword.get(opts, :payload, "ask-#{id}"), meta})
  end

  defp outcome(node, kind, id, value, opts \\ []) do
    meta = %{
      "flz.call_id" => id,
      "channel" => Keyword.get(opts, :channel, "placed"),
      "flz.call_duration_ms" => Keyword.get(opts, :ms, 12)
    }

    FakeController.emit(node, @listen, {kind, value, meta})
  end

  defp shows?(view, fragment), do: FakeController.eventually(fn -> render(view) =~ fragment end)

  defp badge(html, kind, seq) do
    [_, label] = Regex.run(~r/data-testid="call-#{kind}-#{seq}"[^>]*>\s*([^<]+?)\s*</, html)
    label
  end

  defp outcome_of(html, seq), do: badge(html, "outcome", seq)

  describe "holding the listen" do
    test "the panel starts folded with no listen held", %{conn: conn, node: node} do
      {:ok, _view, html} = live(conn, @url)

      refute html =~ ~s(data-testid="section-body-calls")
      assert FakeController.calls(node, @listen) == []
    end

    test "opening it holds a listen, said to listen only once the controller attached", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "calls")
      assert html =~ ~s(data-testid="calls-starting")
      refute html =~ ~s(data-testid="calls-listening")

      assert shows?(view, ~s(data-testid="calls-listening"))
      refute render(view) =~ ~s(data-testid="calls-starting")

      assert [["default", "relay_a", "calls", [], %{token: _}]] =
               FakeController.calls(node, @listen)
    end

    test "folding ends the listen and keeps the rows", %{conn: conn, node: node} do
      view = open_calls(conn, node)
      call(node, "c1")
      assert shows?(view, ~s(data-testid="call-entry-1"))

      open_section(view, "calls")
      assert FakeController.eventually(fn -> FakeController.streams(node, @listen) == [] end)

      open_section(view, "calls")
      assert FakeController.eventually(fn -> FakeController.streams(node, @listen) != [] end)
      assert render(view) =~ ~s(data-testid="call-entry-1")
      assert outcome_of(render(view), 1) == "Outcome not heard"
      assert length(FakeController.calls(node, @listen)) == 2
    end

    test "closing the screen ends the listen", %{conn: conn, node: node} do
      view = open_calls(conn, node)

      # What a LiveView exits with when its socket closes; the test is linked too.
      Process.flag(:trap_exit, true)
      GenServer.stop(view.pid, {:shutdown, :closed})

      assert FakeController.eventually(fn -> FakeController.streams(node, @listen) == [] end)
    end

    test "an ended listen marks waiting calls as not heard and offers to listen again", %{
      conn: conn,
      node: node
    } do
      view = open_calls(conn, node)
      call(node, "c1")
      assert shows?(view, ~s(data-testid="call-entry-1"))
      assert outcome_of(render(view), 1) == "Waiting"

      FakeController.end_stream(node, @listen, {:ok, :relay_ended})

      assert shows?(view, ~s(data-testid="calls-ended"))
      html = render(view)
      assert outcome_of(html, 1) == "Outcome not heard"
      assert html =~ ~s(data-testid="calls-reopen")
    end

    test "listen again holds one new listen, and earlier rows stay unheard", %{
      conn: conn,
      node: node
    } do
      view = open_calls(conn, node)
      call(node, "c1")
      FakeController.end_stream(node, @listen, {:ok, :relay_ended})
      assert shows?(view, ~s(data-testid="calls-reopen"))

      view |> element(~s([data-testid="calls-reopen"])) |> render_click()

      assert FakeController.eventually(fn ->
               length(FakeController.streams(node, @listen)) == 1
             end)

      html = render(view)
      refute html =~ ~s(data-testid="calls-ended")
      refute html =~ ~s(data-testid="calls-reopen")
      assert outcome_of(html, 1) == "Outcome not heard"

      # An outcome the new listen hears for an earlier call changes nothing.
      outcome(node, :answered, "c1", "late answer")
      call(node, "c2")
      assert shows?(view, ~s(data-testid="call-entry-2"))
      html = render(view)
      assert outcome_of(html, 1) == "Outcome not heard"
      refute html =~ "late answer"
    end

    test "a folded panel's forged listen again holds nothing", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)

      render_click(view, "calls_reopen", %{})

      assert FakeController.calls(node, @listen) == []
    end

    test "a refused listen is stated with its code", %{conn: conn, node: node} do
      FakeController.set(
        node,
        @listen,
        FakeController.error("authz.role_insufficient", "no listening for you")
      )

      {:ok, view, _html} = live(conn, @url)
      open_section(view, "calls")

      assert shows?(view, ~s(data-testid="calls-error"))
      html = render(view)
      assert html =~ "no listening for you"
      assert html =~ "authz.role_insufficient"
      assert html =~ ~s(data-testid="calls-reopen")
      assert html =~ ~s(data-testid="diagnose-btn")
    end

    test "a refusal is one error statement with its next step and reference", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        @listen,
        {:error,
         Flezha.Error.new(
           "relay.not_running",
           "relay 'orders' is not running",
           "flz relay list --namespace default"
         )}
      )

      {:ok, view, _html} = live(conn, @url)
      open_section(view, "calls")
      assert shows?(view, ~s(data-testid="calls-error"))
      html = render(view)

      statement = ~s([data-testid="calls-error"] [data-testid="runtime-error"])
      assert html |> LazyHTML.from_fragment() |> LazyHTML.query(statement) |> Enum.count() == 1

      assert text_of(html, ~s(#{statement} [data-testid="runtime-error-hint"])) ==
               "flz relay list --namespace default"

      assert text_of(html, ~s(#{statement} [data-testid="runtime-error-code"])) ==
               "relay.not_running"
    end
  end

  describe "pairing calls with their outcomes" do
    test "a call waits, and its outcome completes the row", %{conn: conn, node: node} do
      view = open_calls(conn, node)
      call(node, "c1", payload: ~s({"pair":"BTC-EUR"}))

      assert shows?(view, ~s(data-call-id="c1"))
      html = render(view)
      assert outcome_of(html, 1) == "Waiting"
      assert html =~ "BTC-EUR"
      assert html =~ "18 B"
      refute html =~ ~s(data-testid="calls-listening")

      outcome(node, :answered, "c1", ~s({"status":"placed"}), channel: "placed", ms: 1_500)

      assert FakeController.eventually(fn -> outcome_of(render(view), 1) == "Answered" end)
      html = render(view)
      assert html =~ "status"
      assert html =~ "1s"
      assert html =~ ~s(<span class="fcon-ident">placed</span>)
    end

    test "calls are listed newest first", %{conn: conn, node: node} do
      view = open_calls(conn, node)
      call(node, "c1")
      call(node, "c2")

      assert shows?(view, ~s(data-testid="call-entry-2"))
      html = render(view)

      {first, _} = :binary.match(html, ~s(data-testid="call-entry-2"))
      {second, _} = :binary.match(html, ~s(data-testid="call-entry-1"))
      assert first < second
    end

    test "fifty-five calls keep the latest fifty", %{conn: conn, node: node} do
      view = open_calls(conn, node)
      for n <- 1..55, do: call(node, "c#{n}")

      assert shows?(view, ~s(data-testid="call-entry-55"))
      html = render(view)
      assert html =~ ~s(data-testid="call-entry-6")
      refute html =~ ~s(data-testid="call-entry-5")
      assert length(Regex.scan(~r/data-testid="call-entry-\d+"/, html)) == 50
    end

    test "an outcome for a call not listed changes nothing", %{conn: conn, node: node} do
      view = open_calls(conn, node)
      call(node, "c1")
      outcome(node, :answered, "unknown", "stray answer")
      call(node, "c2")

      assert shows?(view, ~s(data-testid="call-entry-2"))
      html = render(view)
      refute html =~ "stray answer"
      assert outcome_of(html, 1) == "Waiting"
      assert outcome_of(html, 2) == "Waiting"
    end

    test "a large payload is kept bounded", %{conn: conn, node: node} do
      view = open_calls(conn, node)
      call(node, "c1", payload: String.duplicate("x", 2_000))

      assert shows?(view, ~s(data-testid="call-entry-1"))
      html = render(view)
      assert html =~ String.duplicate("x", 500)
      refute html =~ String.duplicate("x", 501)
    end

    test "a retried relay call gives one row per attempt", %{conn: conn, node: node} do
      view = open_calls(conn, node)
      call(node, "r1", source: "relay", meta: %{"flz.call_caller" => "orders"})
      outcome(node, :refused, "r1", Flezha.Error.new("call.unavailable", "not ready"))
      call(node, "r1", source: "relay", meta: %{"flz.call_caller" => "orders"})
      outcome(node, :answered, "r1", "second time lucky")

      assert FakeController.eventually(fn ->
               html = render(view)
               html =~ ~s(data-testid="call-entry-2") and outcome_of(html, 2) == "Answered"
             end)

      html = render(view)
      assert outcome_of(html, 1) == "Refused"
      assert html =~ "call.unavailable"
      assert html =~ "second time lucky"
    end

    test "each outcome kind reads as itself, a refusal with its code", %{conn: conn, node: node} do
      view = open_calls(conn, node)
      call(node, "a")
      outcome(node, :answered, "a", "fine")
      call(node, "t")
      outcome(node, :timed_out, "t", Flezha.Error.new("call.timeout", "no answer in 500ms"))
      call(node, "b")
      outcome(node, :refused, "b", Flezha.Error.new("call.busy", "too many callers"))

      assert FakeController.eventually(fn ->
               html = render(view)
               html =~ ~s(data-testid="call-outcome-3") and outcome_of(html, 3) == "Refused"
             end)

      html = render(view)
      assert outcome_of(html, 1) == "Answered"
      assert outcome_of(html, 2) == "Timed out"
      assert html =~ "no answer in 500ms"
      assert html =~ ~s(<code data-testid="runtime-error-code">call.timeout</code>)
      assert html =~ "too many callers"
      assert html =~ ~s(<code data-testid="runtime-error-code">call.busy</code>)
      assert html =~ ~r/data-testid="call-outcome-1"[^>]*class="fcon-badge fcon-badge--positive"/
      assert html =~ ~r/data-testid="call-outcome-2"[^>]*class="fcon-badge fcon-badge--warning"/
      assert html =~ ~r/data-testid="call-outcome-3"[^>]*class="fcon-badge fcon-badge--negative"/
    end

    test "each source reads as its badge, a relay naming its caller", %{conn: conn, node: node} do
      view = open_calls(conn, node)

      sources = ~w(ui cli sdk http mcp plugin internal relay something_new)

      for source <- sources,
          do: call(node, source, source: source, meta: %{"flz.call_caller" => "orders"})

      assert shows?(view, ~s(data-testid="call-entry-9"))
      html = render(view)

      labels = for seq <- 1..9, do: badge(html, "source", seq)

      # A source this console does not know is shown as the sender spelled it.
      assert labels == ~w(UI CLI SDK HTTP MCP Plugin Internal Relay something_new)
      assert html =~ ~r/data-testid="call-entry-8".*?orders/s
    end

    test "a call naming no channel shows a dash", %{conn: conn, node: node} do
      view = open_calls(conn, node)

      FakeController.emit(
        node,
        @listen,
        {:call, "hi", %{"flz.call_id" => "c1", "flz.call_source" => "cli"}}
      )

      assert shows?(view, ~s(data-testid="call-entry-1"))
      assert render(view) =~ ~s(<span class="fcon-ident">—</span>)
    end
  end

  describe "beside the payload tap" do
    test "a call does not move the tap, and an output adds no call", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :graph}, FakeController.one_tasklet_graph("relay_a"))
      view = open_calls(conn, node)

      view
      |> element(~s([data-testid="topo-node-exit-out"][phx-click="graph_tap"]))
      |> render_click()

      assert FakeController.eventually(fn ->
               length(FakeController.streams(node, @listen)) == 2
             end)

      call(node, "c1")
      FakeController.emit(node, @listen, {:output, "an output", %{}})

      assert shows?(view, ~s(data-testid="call-entry-1"))
      assert shows?(view, "an output")
      html = render(view)
      refute html =~ ~s(data-testid="call-entry-2")
      assert html =~ ~r/<dt class="topo-muted">Messages<\/dt>\s*<dd[^>]*>\s*1\s*</
    end
  end
end
