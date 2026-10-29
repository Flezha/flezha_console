defmodule FlezhaConsoleWeb.LiveCase do
  @moduledoc """
  Case template for LiveView tests that need a controller to answer them.

  Boots one peer node per test module standing in for the controller (see
  `FakeController`) and logs a user in, so a test only has to say what the
  controller should answer and then drive the screen.

  Never concurrent, and one peer per module rather than per test: the
  controller `NodeManager.connected_node/0` answers is named by `FLEZHA_NODE`,
  which is global VM state, so two modules with their own peers would each
  repoint the other's screens.

  Tagged `:distributed`, so `mix test --exclude distributed` still gives a fast
  inner loop with no peer boots.

      use FlezhaConsoleWeb.LiveCase

      test "renders the namespaces", %{conn: conn, node: node} do
        FakeController.set_fleet(node, namespaces: ["default"])
        {:ok, _view, html} = live(conn, ~p"/namespaces")
        assert html =~ "default"
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use FlezhaConsoleWeb.ConnCase, async: false

      import Phoenix.LiveViewTest

      import FlezhaConsoleWeb.LiveCase,
        only: [
          live_loaded: 2,
          open_section: 2,
          partition_group: 3,
          group_row: 2,
          group_row: 3,
          text_of: 2,
          condition_value: 3,
          testids: 2,
          attributes: 3,
          submit_plugin_form: 2,
          plugin_fields: 1,
          tick: 1,
          enforce_operations: 3,
          grant_operations: 3
        ]

      alias FlezhaConsole.PeerNode
      alias FlezhaConsole.Service.NodeManager

      @moduletag :distributed

      setup_all do
        PeerNode.setup_controller()
      end

      setup %{conn: conn, node: node} do
        # Canned answers are node-global, so without this one test's setup is
        # the next one's surprise.
        FakeController.reset(node)

        user = FlezhaConsole.AccountsFixtures.user_fixture()
        %{conn: log_in_user(conn, user), user: user}
      end
    end
  end

  @doc """
  Opens `path` and answers `{view, html}` once the reads it started in the
  background have answered: Home's own and the shell's pulse. A macro, as
  `live/2` is, so it reaches the test module's endpoint.
  """
  defmacro live_loaded(conn, path) do
    quote do
      {:ok, view, _html} = live(unquote(conn), unquote(path))
      {view, render_async(view)}
    end
  end

  @doc """
  Unfolds one of a long screen's sections and answers the screen with it open.

  The lower panels of the relay and namespace screens start folded, so a
  test that reads one says so first — the same click an operator makes.
  """
  def open_section(view, key) do
    view
    |> Phoenix.LiveViewTest.element(~s([data-testid="section-toggle-#{key}"]))
    |> Phoenix.LiveViewTest.render_click()
  end

  @doc """
  One refresh tick of a screen that shows rates, answered with the render.

  A rate divides a delta by the time since the last reading, so the last
  reading is moved a second into the past rather than waited for. A screen
  that reads in the background skips a tick while a read is in flight, so the
  reads in flight are awaited first, and the tick's own read after.
  """
  def tick(view) do
    Phoenix.LiveViewTest.render_async(view)

    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      %{state | socket: update_in(socket.assigns.topology_state.prev_at, &(&1 && &1 - 1_000))}
    end)

    send(view.pid, :refresh)
    Phoenix.LiveViewTest.render_async(view)
  end

  @doc """
  Answers the namespace's relay list with the partition group `group` of
  `count` members, `group#p0` onwards, collapsed into one row as the
  controller lists a group, beside one relay of no group and another group.
  """
  def partition_group(node, group, count) do
    FakeController.set(
      node,
      {Flezha.Service.Relay, :list},
      FakeController.rows([
        group_row(group, count),
        FakeController.relay_row("relay_a"),
        group_row("other", 2)
      ])
    )
  end

  @doc "A partition group's row as the controller lists it: one row holding its `count` members."
  def group_row(group, count, member \\ fn _index -> %{} end) do
    members =
      for i <- 0..(count - 1) do
        FakeController.relay_row(
          "#{group}#p#{i}",
          Map.merge(
            %{partition: %{group: group, index: i, count: count, range: {i * 64, i * 64 + 63}}},
            member.(i)
          )
        )
      end

    rank = FlezhaConsole.Service.NodeManager.health_verdicts()

    worst =
      members |> Enum.map(& &1.health) |> Enum.max_by(&Enum.find_index(rank, fn h -> h == &1 end))

    Map.merge(FakeController.relay_row(group), %{
      health: worst,
      partitions: "#{count}/#{count}",
      members: members
    })
  end

  @doc """
  Submits the plugin form with `fields`, and on an enable keeps submitting
  them, a step at a time, until the flow stops moving on: at a failed check,
  a refusal, or once it enabled. A test states the fields once, as an
  operator who filled every step would have. A bind or an update is one
  submit.
  """
  def submit_plugin_form(view, fields) do
    step = plugin_step(Phoenix.LiveViewTest.render(view))
    {typed, picked} = plugin_fields(fields)

    html =
      view
      |> Phoenix.LiveViewTest.form(~s(form[phx-submit="plugin_form_submit"]), plugin: typed)
      |> Phoenix.LiveViewTest.render_submit(%{plugin: picked})

    case {step, plugin_step(html)} do
      {from, to} when is_integer(from) and is_integer(to) and to > from ->
        submit_plugin_form(view, fields)

      _stopped ->
        html
    end
  end

  @doc """
  The plugin form's `fields` split into what a test types into the form and
  what its pickers hold: a picker's option sets the form's hidden value in
  the browser, so a test sends it with the event instead.
  """
  def plugin_fields(fields) do
    fields
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.split_with(fn {key, _value} -> key not in ~w(namespace relay_id) end)
  end

  defp plugin_step(html) do
    case html
         |> LazyHTML.from_document()
         |> LazyHTML.query(~s([data-testid="plugin-steps"]))
         |> LazyHTML.attribute("data-step") do
      [step] -> String.to_integer(step)
      [] -> nil
    end
  end

  @doc """
  The text of what `selector` matches in `html`, its whitespace collapsed as a
  browser shows it.
  """
  def text_of(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  The value of a condition row `key` under the condition `testid`, as it reads
  on the page: a glossary term's words without its definition.
  """
  def condition_value(html, testid, key) do
    row = ~s([data-testid="#{testid}-#{key}"])

    case text_of(html, row <> " .fcon-term") do
      "" -> text_of(html, row <> " dd")
      term -> term
    end
  end

  @doc "The `data-testid` of each element `selector` matches in `html`, in page order."
  def testids(html, selector), do: attributes(html, selector, "data-testid")

  @doc "The attribute `name` of each element `selector` matches in `html`, in page order."
  def attributes(html, selector, name) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  @doc """
  Binds `user` to a token that verifies as `identity` under an enforced
  posture: the only setup in which a screen's controls follow the operations
  whoami grants (`grant_operations/3`). `identity` is `%{principal:,
  namespace:, role:}`.
  """
  def enforce_operations(node, user, identity) do
    token = "flzt_#{System.unique_integer([:positive])}"
    {:ok, _user} = FlezhaConsole.Accounts.update_user_flezha_token(user, token)
    FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, :enforced)

    FakeController.set(
      node,
      {Flezha.Service.Admin, :context},
      {:ok, Map.put(identity, :source, :ui)}
    )
  end

  @doc "Makes whoami answer `identity` with exactly `operations` granted."
  def grant_operations(node, identity, operations) do
    FakeController.set(
      node,
      {Flezha.Service.Namespace, :whoami},
      {:ok, Map.put(identity, :operations, operations)}
    )
  end
end
