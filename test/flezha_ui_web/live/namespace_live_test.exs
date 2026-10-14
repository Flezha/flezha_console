defmodule FlezhaUiWeb.NamespaceLiveTest do
  @moduledoc """
  The namespace index and show screens.

  The browser suite drives the happy path against the seeded `default`
  namespace. Covered here instead: an empty controller, a controller that
  refuses, and the start form's validation branches — which the browser cannot
  reach without leaving half-started relays behind.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.Relay

  # A namespace's relays, as every listing reads them. An id alone is the
  # ordinary case; a map is a row a test wants to say more about.
  defp with_relays(node, relays, opts \\ []) do
    rows = Enum.map(relays, &row/1)
    FakeController.set_fleet(node, Keyword.merge([rows: %{"default" => rows}], opts))
    rows
  end

  defp row(%{} = row), do: FakeController.relay_row(row[:id] || "relay", row)
  defp row(id), do: FakeController.relay_row(id)

  describe "the index" do
    test "counts each namespace's relays and runners", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        {:ok, [%{namespace: "default", running: true}]}
      )

      FakeController.set(
        node,
        {Relay, :relay_rows},
        {:ok, [FakeController.relay_row("a"), FakeController.relay_row("b")]}
      )

      FakeController.set(node, {Fleet, :runners}, {:ok, [%{id: "runner-a", pid: nil}]})

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert text_of(html, ~s([data-testid="namespace-relays-default"])) == "2 relays"
      assert text_of(html, ~s([data-testid="namespace-runners-default"])) == "1 runner"
    end

    test "a namespace whose relays cannot be counted still lists", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        {:ok, [%{namespace: "default", running: true}, %{namespace: "staging", running: true}]}
      )

      FakeController.set(
        node,
        {Relay, :relay_rows},
        {:per_arg, 0, %{"default" => FakeController.error("controller.timeout")},
         {:ok, [FakeController.relay_row("a")]}}
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      # One failing count must not take the whole page down with it.
      assert text_of(html, ~s([data-testid="namespace-relays-default"])) == "0 relays"
      assert text_of(html, ~s([data-testid="namespace-relays-staging"])) == "1 relay"
    end
  end

  # A relay's lane on Home's map, as its accessible name reads it.
  defp lane(html, id) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([data-testid="map-lane-#{id}"]))
    |> LazyHTML.attribute("aria-label")
    |> List.first()
  end

  describe "the show page" do
    test "draws the relays running in the namespace on its map", %{conn: conn, node: node} do
      with_relays(node, ["relay_a", "relay_b"])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="namespace-map")
      assert lane(html, "relay_a")
      assert lane(html, "relay_b")
    end
  end

  describe "relay health" do
    test "the node, factory and runner come from the same rows", %{conn: conn, node: node} do
      with_relays(node, [
        %{id: "relay_a", node: :"flezha@node-b", factory: "compare_filter", runner: "runner-z"}
      ])

      FakeController.set(node, {Fleet, :runners}, {:ok, [%{id: "runner-z", pid: nil}]})

      {:ok, view, html} = live(conn, ~p"/namespaces/default")

      assert lane(html, "relay_a") =~ "compare_filter"
      assert html =~ "runner-z"

      view |> element(~s([data-testid="map-lane-relay_a"])) |> render_click()
      assert render(view) =~ "flezha@node-b"
    end

    test "a listing tick costs the same whether the namespace holds two or fifty", %{
      conn: conn,
      node: node
    } do
      with_relays(node, ["relay_a", "relay_b"])
      {:ok, _view, _html} = live(conn, ~p"/namespaces/default")
      small = length(FakeController.calls(node, {Relay, :list}))

      FakeController.reset(node)
      with_relays(node, Enum.map(1..50, &"relay_#{&1}"))
      {:ok, _view, _html} = live(conn, ~p"/namespaces/default")
      large = length(FakeController.calls(node, {Relay, :list}))

      assert small == large
      # And nothing was asked per relay.
      assert FakeController.calls(node, {Relay, :overwatch_state}) == []
    end
  end

  describe "partition groups" do
    defp members do
      [
        FakeController.relay_row("orders_p0", %{
          partition: %{group: "orders", index: 0, count: 2, range: {0, 127}}
        }),
        FakeController.relay_row("orders_p1", %{
          health: :degraded,
          partition: %{group: "orders", index: 1, count: 2, range: {128, 255}}
        })
      ]
    end

    defp with_group(node, coverage \\ :ok) do
      FakeController.set_fleet(node, rows: %{"default" => members()})

      FakeController.set(
        node,
        {Relay, :partition_groups},
        {:ok, [%{group: "orders", declared: 2, members: members(), coverage: coverage}]}
      )
    end

    test "a complete group shows its member count and is not faulted", %{conn: conn, node: node} do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "partition-groups")

      assert html =~ ~s(data-testid="partition-group-orders")
      assert html =~ ~s(data-testid="group-members-orders")
      assert html =~ "2/2"
      refute html =~ ~s(data-testid="group-faulted-orders")
    end

    test "the group reports its sickest member's health", %{conn: conn, node: node} do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert open_section(view, "partition-groups") =~ ~s(data-health="degraded")
    end

    test "members are listed with partition index, key range and health", %{
      conn: conn,
      node: node
    } do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "partition-groups")

      assert html =~ "p0"
      assert html =~ "p1"
      assert html =~ "0–127"
      assert html =~ "128–255"
      assert html =~ "orders_p0"
    end

    test "a coverage gap is a fault, and the uncovered range is named", %{conn: conn, node: node} do
      with_group(node, {:error, %{gaps: [{128, 255}], overlaps: []}})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "partition-groups")

      assert html =~ ~s(data-testid="group-faulted-orders")
      assert html =~ ~s(data-testid="group-coverage-orders")
      assert html =~ "owned by no member"
    end

    test "overlapping owners are a fault, and both are named", %{conn: conn, node: node} do
      with_group(node, {:error, %{gaps: [], overlaps: [{7, ["orders_p0", "orders_p1"]}]}})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "partition-groups")

      assert html =~ ~s(data-testid="group-faulted-orders")
      assert html =~ "claimed by orders_p0, orders_p1"
    end

    test "a cancelled rescale target is dropped, and one below one is not taken", %{
      conn: conn,
      node: node
    } do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_section(view, "partition-groups")

      view |> element(~s([data-testid="rescale-orders"])) |> render_click()
      rescale_target(view, "3")
      view |> element(~s([data-testid="rescale-cancel-btn"])) |> render_click()

      view |> element(~s([data-testid="rescale-orders"])) |> render_click()
      rescale_target(view, "0")
      view |> element(~s([data-testid="rescale-confirm-btn"])) |> render_click()

      assert [["default", "orders", 2, [], %{source: :ui}]] =
               FakeController.calls(node, {Flezha.Service.Steps, :rescale})
    end

    defp rescale_target(view, target) do
      view
      |> form(~s(form[phx-change="select_rescale"]), rescale: %{target: target})
      |> render_change()
    end

    test "a namespace with no groups renders no group panel", %{conn: conn, node: node} do
      with_relays(node, ["relay_a"])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      refute html =~ ~s(data-testid="partition-groups")
    end
  end

  describe "finished relays" do
    test "lists the finished relays the controller retains", %{conn: conn, node: node} do
      with_relays(node, ["relay_a"])

      FakeController.set(
        node,
        {Relay, :info},
        {:ok,
         %{
           namespace: "default",
           groups: [],
           relays: [
             %{id: "relay_a", phase: "running"},
             %{id: "echo_1", phase: "finished", status: :completed, finished_at: 1_700_000_000}
           ]
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      html = open_section(view, "finished-relays")

      assert html =~ ~s(data-testid="finished-row-echo_1")
      refute html =~ ~s(data-testid="finished-row-relay_a")
    end

    test "a refused read is stated, not shown as empty", %{conn: conn, node: node} do
      with_relays(node, [])
      FakeController.set(node, {Relay, :info}, FakeController.error("authz.role_insufficient"))

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert open_section(view, "finished-relays") =~ "authz.role_insufficient"
    end
  end

  describe "stopping a relay" do
    setup %{node: node} do
      with_relays(node, ["relay_a"])
      :ok
    end

    # The map's lane opens the relay's inspector, whose Stop asks first.
    defp stop(view) do
      view |> element(~s([data-testid="map-lane-relay_a"])) |> render_click()
      view |> element(~s([data-testid="inspector-stop"])) |> render_click()
      view |> element(~s([data-testid="stop-confirm-btn"])) |> render_click()
    end

    test "confirming reaches the controller", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      stop(view)

      assert [["default", "relay_a", %{source: :ui}]] = FakeController.calls(node, {Relay, :stop})
    end

    test "a cooperative stop says the relay finishes its work first", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :stop}, {:ok, %{id: "relay_a", stopped: :cooperative}})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert stop(view) =~ "finishes its in-flight work"
    end

    test "surfaces a refused stop", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :stop}, FakeController.error("relay.not_found"))

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert stop(view) =~ "relay.not_found (test)"
    end
  end
end
