defmodule FlezhaUiWeb.RelayCallsTest do
  @moduledoc """
  Asking a relay what is wrong with it, reading its announced API, and talking
  to it from the relay detail screen: the diagnosis panel, the API section and
  the dialog that sends to the relay, calls it, or calls an entry channel from a
  form generated from the channel's schema.

  The verdicts, refusals and answer shapes worth asserting are ones a live
  relay will not produce on demand.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.Relay

  @url "/namespaces/default/relays/relay_a"

  setup %{node: node} do
    FakeController.set(node, {Relay, :overwatch_state}, {:ok, %{factory_id: "orders"}})
    FakeController.set(node, {Relay, :relay_rows}, {:ok, [FakeController.relay_row("relay_a")]})
    FakeController.set(node, {Fleet, :runners_for_factory}, {:ok, ["runner-a"]})
    :ok
  end

  defp finding(level, code, overrides \\ %{}) do
    Map.merge(
      %{level: level, code: code, message: "#{code} said so", details: %{}, hint: nil},
      overrides
    )
  end

  defp diagnosis(node, verdict, findings),
    do:
      FakeController.set(
        node,
        {Relay, :diagnose},
        {:ok, %{relay: "relay_a", verdict: verdict, findings: findings}}
      )

  defp diagnose(view), do: view |> element(~s([data-testid="diagnose-btn"])) |> render_click()

  @place %{
    channel: "place",
    codec: "json",
    description: "Places an order",
    schema: %{
      "type" => "object",
      "properties" => %{"pair" => %{"type" => "string"}, "amount" => %{"type" => "number"}},
      "required" => ["pair", "amount"]
    },
    answer_codec: "json",
    answer_schema: nil
  }

  @audit %{
    channel: "audit",
    codec: "text",
    description: nil,
    schema: nil,
    answer_codec: nil,
    answer_schema: nil
  }

  defp api(node, channels, overrides \\ %{}) do
    entry =
      Map.merge(
        %{
          factory: "orders",
          description: "Order intake",
          channels: channels,
          disagree: false,
          relay: "relay_a"
        },
        overrides
      )

    FakeController.set(node, {Relay, :api}, {:ok, [entry]})
  end

  defp field_error(name), do: ~s([data-testid="talk-field-#{name}"] ~ .fui-error)

  defp talk(view), do: view |> element(~s([data-testid="talk-open-btn"])) |> render_click()

  defp submit_channel(view, talk) do
    view
    |> form(~s([data-testid="talk-channel-form"]), %{"talk" => talk})
    |> render_submit()
  end

  defp submit_raw(view, fields, action) do
    view
    |> form(~s([data-testid="talk-raw-form"]), %{"talk" => fields})
    |> put_submitter(~s([data-testid="talk-#{action}-btn"]))
    |> render_submit()
  end

  defp raw(view, fields, action) do
    submit_raw(view, fields, action)
    render_async(view)
  end

  defp close_talk(view),
    do: view |> element(~s([data-testid="talk-close-btn"])) |> render_click()

  describe "diagnosis" do
    test "a relay with only notes is ok, each note listed with its code", %{
      conn: conn,
      node: node
    } do
      diagnosis(node, :ok, [finding(:note, "diagnose.healthy")])
      {:ok, view, html} = live(conn, @url)

      refute html =~ ~s(data-testid="diagnose-verdict")
      html = diagnose(view)

      assert html =~ ~r/data-testid="diagnose-verdict"[^>]*>\s*No fault found/
      assert html =~ ~s(data-testid="diagnose-finding-diagnose.healthy")
      assert html =~ "diagnose.healthy said so"
      assert html =~ ~s(<code data-testid="runtime-error-code">diagnose.healthy</code>)
      assert html =~ ~s(href="https://docs.flezha.com/errors.html#diagnose")
    end

    test "a problem shows its hint as the next command", %{conn: conn, node: node} do
      diagnosis(node, :problem, [
        finding(:problem, "diagnose.no_runner", %{hint: "flz runner list --namespace default"})
      ])

      {:ok, view, _html} = live(conn, @url)
      html = diagnose(view)

      assert html =~ ~r/data-testid="diagnose-verdict"[^>]*>\s*A problem/
      assert html =~ "flz runner list --namespace default"
    end

    test "a finished relay's finding carries its completion status", %{conn: conn, node: node} do
      diagnosis(node, :warning, [
        finding(:warning, "diagnose.finished", %{message: "finished with status failed"})
      ])

      {:ok, view, _html} = live(conn, @url)

      assert diagnose(view) =~ "finished with status failed"
    end

    test "is never part of the tick", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      send(view.pid, :refresh)
      render(view)

      assert FakeController.calls(node, {Relay, :diagnose}) == []
    end

    test "running it again replaces the findings", %{conn: conn, node: node} do
      diagnosis(node, :problem, [finding(:problem, "diagnose.no_runner")])
      {:ok, view, _html} = live(conn, @url)
      diagnose(view)

      diagnosis(node, :ok, [finding(:note, "diagnose.healthy")])
      html = diagnose(view)

      assert html =~ "diagnose-finding-diagnose.healthy"
      refute html =~ "diagnose-finding-diagnose.no_runner"
      assert length(FakeController.calls(node, {Relay, :diagnose})) == 2
    end

    test "an unknown relay shows the error instead of a verdict", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :diagnose}, FakeController.error("relay.not_found"))
      {:ok, view, _html} = live(conn, @url)
      html = diagnose(view)

      assert html =~ ~s(data-testid="diagnose-error")
      assert html =~ "relay.not_found"
      refute html =~ ~s(data-testid="diagnose-verdict")
    end
  end

  describe "the API section" do
    test "lists each channel with its format, answer and schema", %{conn: conn, node: node} do
      api(node, [@place, @audit])
      {:ok, view, _html} = live(conn, @url)
      html = open_section(view, "api")

      assert html =~ ~s(data-testid="api-channel-place")
      assert html =~ "Places an order"
      assert html =~ "Yes, json"
      assert html =~ ~s(data-testid="api-schema-place")
      assert html =~ ~s(data-testid="api-channel-audit")
      refute html =~ ~s(data-testid="api-schema-audit")
    end

    test "a factory with no API says so and keeps the raw controls", %{conn: conn, node: node} do
      api(node, [])
      {:ok, view, _html} = live(conn, @url)
      html = open_section(view, "api")

      assert html =~ ~s(data-testid="api-none")
      assert html =~ ~s(data-testid="talk-open-btn")
    end

    test "runners that disagree are stated", %{conn: conn, node: node} do
      api(node, [@place], %{disagree: true})
      {:ok, view, _html} = live(conn, @url)

      assert open_section(view, "api") =~ ~s(data-testid="api-disagree")
    end

    test "is read on mount and on opening, never on the tick", %{conn: conn, node: node} do
      api(node, [@place])
      {:ok, view, _html} = live(conn, @url)
      assert length(FakeController.calls(node, {Relay, :api})) == 1

      send(view.pid, :refresh)
      render(view)
      assert length(FakeController.calls(node, {Relay, :api})) == 1

      open_section(view, "api")

      assert [["default", "relay_a", _], ["default", "relay_a", _]] =
               FakeController.calls(node, {Relay, :api})
    end
  end

  describe "calling an entry channel" do
    test "a flat object schema becomes one field per property", %{conn: conn, node: node} do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "side" => %{"enum" => ["buy", "sell"]},
          "price" => %{"type" => "number"},
          "lots" => %{"type" => "integer"},
          "urgent" => %{"type" => "boolean"}
        },
        "required" => ["name"]
      }

      api(node, [%{@place | schema: schema}])
      {:ok, view, _html} = live(conn, @url)
      html = talk(view)

      for field <- ~w(name side price lots urgent),
          do: assert(html =~ ~s(data-testid="talk-field-#{field}"))

      assert html =~ "name *"
      assert html =~ ~s(<option value="sell")
      refute html =~ ~s(data-testid="talk-json")
    end

    test "the dialog switches between the channel and a raw message", %{conn: conn, node: node} do
      api(node, [@place])
      {:ok, view, _html} = live(conn, @url)
      assert talk(view) =~ ~s(data-testid="talk-channel-form")

      html = view |> element(~s([data-testid="talk-mode-raw"])) |> render_click()
      assert html =~ ~s(data-testid="talk-raw-form")
      refute html =~ ~s(data-testid="talk-channel-form")

      html = view |> element(~s([data-testid="talk-mode-channel"])) |> render_click()
      assert html =~ ~s(data-testid="talk-channel-form")
    end

    test "calls the channel with the value built from the fields", %{conn: conn, node: node} do
      api(node, [@place])

      FakeController.set(
        node,
        {Relay, :call_channel},
        {:ok, %{answer: %{"status" => "placed"}, answer_codec: "json"}}
      )

      {:ok, view, _html} = live(conn, @url)
      talk(view)

      submit_channel(view, %{
        "value" => %{"pair" => "BTC-EUR", "amount" => "1.5"},
        "deadline_ms" => "500"
      })

      html = render_async(view)

      assert [["default", "relay_a", "place", value, [deadline_ms: 500], _ctx]] =
               FakeController.calls(node, {Relay, :call_channel})

      assert value == %{"pair" => "BTC-EUR", "amount" => 1.5}
      assert html =~ ~s(data-testid="talk-answer")
      assert html =~ "placed"
      assert html =~ "Answer, <span class=\"font-mono\">json</span>"
    end

    test "a channel that does not answer reports that the input was accepted", %{
      conn: conn,
      node: node
    } do
      api(node, [@audit])
      {:ok, view, _html} = live(conn, @url)
      html = talk(view)
      assert html =~ "does not answer"

      submit_channel(view, %{"json" => "a line"})

      assert render_async(view) =~ "The relay accepted the input."

      assert [["default", "relay_a", "audit", "a line", _opts, _ctx]] =
               FakeController.calls(node, {Relay, :call_channel})
    end

    test "an enum keeps the type its schema lists", %{conn: conn, node: node} do
      schema = %{
        "type" => "object",
        "properties" => %{"lots" => %{"enum" => [1, 2, 3]}},
        "required" => ["lots"]
      }

      api(node, [%{@place | schema: schema}])
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      submit_channel(view, %{"value" => %{"lots" => "2"}})
      render_async(view)

      assert [["default", "relay_a", "place", %{"lots" => 2}, _opts, _ctx]] =
               FakeController.calls(node, {Relay, :call_channel})
    end

    test "an empty required property is named and nothing is called", %{conn: conn, node: node} do
      api(node, [@place])
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      submit_channel(view, %{"value" => %{"pair" => "BTC-EUR"}})

      assert has_element?(view, field_error("amount"), "is required")
      refute has_element?(view, field_error("pair"))
      refute has_element?(view, ~s([data-testid="talk-error"]))
      assert FakeController.calls(node, {Relay, :call_channel}) == []
    end

    test "a schema with more properties than the form can hold is entered as JSON", %{
      conn: conn,
      node: node
    } do
      properties = Map.new(1..129, &{"p#{&1}", %{"type" => "string"}})
      api(node, [%{@place | schema: %{"type" => "object", "properties" => properties}}])
      {:ok, view, _html} = live(conn, @url)

      html = talk(view)
      assert html =~ ~s(data-testid="talk-json")
      refute html =~ ~s(data-testid="talk-field-p1")
    end

    test "every failing property is named on its own field", %{conn: conn, node: node} do
      schema = %{
        "type" => "object",
        "properties" => %{"lots" => %{"type" => "integer"}, "price" => %{"type" => "number"}},
        "required" => ["lots"]
      }

      api(node, [%{@place | schema: schema}])
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      submit_channel(view, %{"value" => %{"lots" => "1.5", "price" => "cheap"}})

      assert has_element?(view, field_error("lots"), "must be a whole number")
      assert has_element?(view, field_error("price"), "must be a number")
      assert FakeController.calls(node, {Relay, :call_channel}) == []
    end

    test "a schema that is not a flat object is entered as JSON, checked first", %{
      conn: conn,
      node: node
    } do
      nested = %{
        "type" => "object",
        "properties" => %{"order" => %{"type" => "object"}}
      }

      api(node, [%{@place | schema: nested}])
      {:ok, view, _html} = live(conn, @url)

      assert talk(view) =~ ~s(data-testid="talk-json")

      html = submit_channel(view, %{"json" => "{not json"})

      assert html =~ "The value must be valid JSON."
      assert FakeController.calls(node, {Relay, :call_channel}) == []
    end

    test "a refused call shows the error with its code and hint", %{conn: conn, node: node} do
      api(node, [@audit])

      FakeController.set(
        node,
        {Relay, :call_channel},
        {:error, Flezha.Error.new("api.channel_unknown", "no channel audit", "flz relay api")}
      )

      {:ok, view, _html} = live(conn, @url)
      talk(view)
      submit_channel(view, %{"json" => "x"})
      html = render_async(view)

      assert html =~ ~s(data-testid="talk-result")
      refute html =~ ~s(data-testid="talk-error")
      assert html =~ "api.channel_unknown"
      assert html =~ "flz relay api"
    end
  end

  describe "a relay nothing can run" do
    setup %{node: node} do
      api(node, [])
      FakeController.set(node, {Fleet, :runners_for_factory}, {:ok, []})
      :ok
    end

    test "keeps Send open, notes what happens to a message, and refuses Call",
         %{conn: conn, node: node} do
      {:ok, view, html} = live(conn, @url)

      refute has_element?(view, ~s([data-testid="talk-open-btn"][disabled]))

      note = text_of(html, ~s([data-testid="talk-unavailable"]))
      assert note =~ "the controller keeps the message only if this relay journals its input"
      assert note =~ "Call is off. Nobody can answer a call until a runner serves factory orders"

      html = talk(view)
      assert html =~ ~s(data-testid="talk-send-note")
      assert has_element?(view, ~s([data-testid="talk-call-btn"][disabled]))
      refute has_element?(view, ~s([data-testid="talk-send-btn"][disabled]))

      assert [["default", "orders", _ctx] | _] =
               FakeController.calls(node, {Fleet, :runners_for_factory})
    end

    test "a send to a suspended relay is kept until it wakes", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:ok, %{factory_id: "orders", suspended: true}}
      )

      FakeController.set(node, {Relay, :send}, {:ok, %{to: "relay_a", verdict: :suspended}})

      {:ok, view, _html} = live(conn, @url)
      assert talk(view) =~ "the message is kept until one connects"

      submit_raw(view, %{"payload" => "hello"}, "send")
      html = render_async(view)

      assert text_of(html, ~s([data-testid="talk-result"])) =~ "Kept until it wakes"

      assert [["default", "relay_a", "hello", "", [], _ctx]] =
               FakeController.calls(node, {Relay, :send})
    end

    test "a forged call is refused and nothing is called", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      html =
        render_submit(view, "talk_submit", %{
          "talk" => %{"payload" => "x", "deadline_ms" => "1000", "action" => "call"}
        })

      assert html =~ "Nobody can answer a call until a runner serves factory orders"
      assert FakeController.calls(node, {Relay, :call}) == []
    end

    test "the deep link opens the dialog on the raw form", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url <> "?do=talk")

      html = render(view)
      assert html =~ ~s(data-testid="talk-modal")
      assert html =~ ~s(data-testid="talk-raw-form")
      assert has_element?(view, ~s([data-testid="talk-call-btn"][disabled]))
    end

    test "a runner serving the factory turns Call back on", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      assert has_element?(view, ~s([data-testid="talk-unavailable"]))

      FakeController.set(node, {Fleet, :runners_for_factory}, {:ok, ["runner-a"]})
      send(view.pid, {:flezha_event, :runner_connected, {"default", "runner-a"}})

      refute has_element?(view, ~s([data-testid="talk-unavailable"]))
      talk(view)
      refute has_element?(view, ~s([data-testid="talk-call-btn"][disabled]))
    end
  end

  describe "a raw message" do
    setup %{node: node} do
      api(node, [])
      :ok
    end

    test "is sent, and the receiving relay and its verdict are shown", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      assert talk(view) =~ ~s(data-testid="talk-payload")

      html = raw(view, %{"payload" => "hello", "channel" => "trades", "msg_id" => "m-1"}, "send")

      assert [["default", "relay_a", "hello", "trades", [msg_id: "m-1"], _ctx]] =
               FakeController.calls(node, {Relay, :send})

      assert html =~ "Delivered to"
    end

    test "a repeated message id reads as absorbed", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :send}, {:ok, %{to: "relay_a", verdict: :absorbed}})
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      assert raw(view, %{"payload" => "hello", "msg_id" => "m-1"}, "send") =~
               "Already received"
    end

    test "a suspended relay journals it", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :send}, {:ok, %{to: "relay_a", verdict: :suspended}})
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      assert raw(view, %{"payload" => "hello"}, "send") =~ "Kept until it wakes"
    end

    test "is called with its deadline and the answer is shown", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :call}, {:ok, "pong", %{"channel" => "replies"}})
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      html = raw(view, %{"payload" => "ping", "deadline_ms" => "45000"}, "call")

      assert [["default", "relay_a", "ping", "", [deadline_ms: 45_000], _ctx]] =
               FakeController.calls(node, {Relay, :call})

      assert html =~ "pong"
      assert html =~ "replies"
    end

    test "no answer in time is the controller's error", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :call},
        {:error, Flezha.Error.new("call.timeout", "no answer in 100ms", "raise the deadline")}
      )

      {:ok, view, _html} = live(conn, @url)
      talk(view)

      html = raw(view, %{"payload" => "ping", "deadline_ms" => "100"}, "call")

      assert html =~ "call.timeout"
      assert html =~ "raise the deadline"
    end

    test "a deadline that is not a positive number is named and nothing is called", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      for deadline <- ["", "0", "soon", "300001"] do
        html = submit_raw(view, %{"payload" => "ping", "deadline_ms" => deadline}, "call")

        assert html =~ "The deadline must be a whole number of milliseconds from 1 to 300000."
      end

      assert FakeController.calls(node, {Relay, :call}) == []
    end
  end

  describe "this session's results" do
    setup %{node: node} do
      api(node, [])
      :ok
    end

    defp results(html), do: Regex.scan(~r/data-testid="talk-result"/, html) |> length()

    test "two calls are both kept, the latest first", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      raw(view, %{"payload" => "first"}, "call")
      html = raw(view, %{"payload" => "second"}, "call")

      assert results(html) == 2
      {second, _} = :binary.match(html, "second")
      {first, _} = :binary.match(html, "first")
      assert second < first
    end

    test "closing and reopening the dialog keeps them", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)
      talk(view)
      raw(view, %{"payload" => "kept"}, "call")

      refute close_talk(view) =~ ~s(data-testid="talk-results")
      html = talk(view)

      assert html =~ ~s(data-testid="talk-results")
      assert html =~ "kept"
    end

    test "eleven results keep the latest ten", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      html =
        Enum.reduce(1..11, nil, fn n, _html ->
          raw(view, %{"payload" => "answer-#{n}"}, "call")
        end)

      assert results(html) == 10
      assert html =~ "answer-11"
      refute html =~ ~r/answer-1\b/
    end

    test "a failure is kept with its code, a validation message is not", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :call},
        {:error, Flezha.Error.new("call.timeout", "no answer in 100ms")}
      )

      {:ok, view, _html} = live(conn, @url)
      talk(view)

      html = raw(view, %{"payload" => "ping", "deadline_ms" => "100"}, "call")
      assert results(html) == 1
      assert html =~ "no answer in 100ms"
      assert html =~ ~s(<code data-testid="runtime-error-code">call.timeout</code>)

      html = submit_raw(view, %{"payload" => "ping", "deadline_ms" => "soon"}, "call")

      assert html =~ ~s(data-testid="talk-error")
      assert results(html) == 1
    end

    test "a refused send is named as the send", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :send},
        FakeController.error("authz.role_insufficient", "no sending here")
      )

      {:ok, view, _html} = live(conn, @url)
      talk(view)

      assert raw(view, %{"payload" => "one way"}, "send") =~
               "The controller refused the send: no sending here"
    end

    test "a send's verdict is kept beside a call's answer", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      raw(view, %{"payload" => "one way"}, "send")
      html = raw(view, %{"payload" => "round trip"}, "call")

      assert results(html) == 2
      assert html =~ "Delivered to"
      assert html =~ "round trip"
    end

    test "a request whose task exits is kept as a failure" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, talk: %{waiting: :call}, talk_results: []}
      }

      {:noreply, socket} = FlezhaUiWeb.RelayLive.handle_async(:talk, {:exit, :killed}, socket)

      assert %{talk: %{waiting: nil}, talk_results: [result]} = socket.assigns
      assert %{kind: :call, error: {:remote_error, :killed}} = result
    end
  end

  describe "a waiting call" do
    setup %{node: node} do
      api(node, [])
      :ok
    end

    test "is stated while it waits and the screen keeps refreshing", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      html = submit_raw(view, %{"payload" => "ping", "deadline_ms" => "1000"}, "call")

      assert html =~ ~s(data-testid="talk-waiting")

      rows_before = length(FakeController.calls(node, {Relay, :relay_rows}))
      send(view.pid, :refresh)
      render(view)
      assert length(FakeController.calls(node, {Relay, :relay_rows})) > rows_before

      refute render_async(view) =~ ~s(data-testid="talk-waiting")
    end

    test "closing the dialog leaves the screen usable", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)
      talk(view)

      submit_raw(view, %{"payload" => "ping", "deadline_ms" => "1000"}, "call")

      html = close_talk(view)
      refute html =~ ~s(data-testid="talk-modal")

      html = render_async(view)
      refute html =~ ~s(data-testid="talk-modal")
      assert html =~ ~s(data-testid="diagnose-btn")
    end
  end
end
