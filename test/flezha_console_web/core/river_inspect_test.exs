defmodule FlezhaConsoleWeb.RiverInspectTest do
  use ExUnit.Case, async: true

  alias FlezhaConsoleWeb.Inspect
  alias FlezhaConsoleWeb.River

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  defp entry(event, namespace, relay, extra \\ %{}) do
    Map.merge(
      %{
        event: event,
        namespace: namespace,
        relay: relay,
        factory: "store_input",
        runner: nil,
        reason: nil,
        at: DateTime.utc_now()
      },
      extra
    )
  end

  describe "the river" do
    test "a relay starting is said with its factory, newest first" do
      s = socket(%{river: [], shell_namespaces: ["default"], scoped_namespace: nil})
      s = River.lifecycle(s, "default", entry(:relay_started, "default", "orders"))

      s =
        River.lifecycle(
          s,
          "default",
          entry(:relay_stopped, "default", "orders", %{reason: :normal})
        )

      assert [%{text: "stopped: " <> _}, %{text: "started from store_input", object: "orders"}] =
               s.assigns.river
    end

    test "an event from an unreachable namespace, or another namespace's on a scoped screen, is not shown" do
      s =
        socket(%{
          river: [],
          shell_namespaces: ["default", "billing"],
          scoped_namespace: "default"
        })

      assert River.lifecycle(s, "secret", entry(:relay_started, "secret", "x")) == s
      assert River.lifecycle(s, "billing", entry(:relay_started, "billing", "x")) == s
    end

    test "a signal naming no namespace is not shown" do
      s = socket(%{river: [], shell_namespaces: ["default"], scoped_namespace: nil})

      assert River.lifecycle(s, nil, entry(:relay_started, nil, "x")) == s
      assert River.runner(s, :runner_dropped, {nil, "runner-a"}) == s
    end

    test "it keeps the fifty most recent" do
      s = socket(%{river: [], shell_namespaces: ["default"], scoped_namespace: nil})

      s =
        Enum.reduce(1..60, s, fn i, s ->
          River.lifecycle(s, "default", entry(:relay_started, "default", "r#{i}"))
        end)

      assert length(s.assigns.river) == 50
      assert hd(s.assigns.river).object == "r60"
    end

    test "runner events and attention diffs join it; a host without a river is untouched" do
      s = socket(%{river: [], shell_namespaces: ["default"], scoped_namespace: nil})
      s = River.runner(s, :runner_connected, {"default", "r1"})

      item = %{
        namespace: "default",
        object: %{id: "orders"},
        what: "orders is suspended",
        severity: :warning
      }

      s = River.attention(s, [item], [])
      s = River.attention(s, [], [item])

      assert Enum.map(s.assigns.river, & &1.kind) == [:cleared, :appeared, :runner_connected]

      bare = socket(%{})
      assert River.runner(bare, :runner_connected, {"default", "r1"}) == bare
    end
  end

  describe "the inspect address" do
    test "parses a kind and an id, and refuses anything else" do
      assert Inspect.parse(%{"inspect" => "relay:orders"}) == {"relay", "orders"}
      assert Inspect.parse(%{"inspect" => "entry:a/b/c"}) == {"entry", "a/b/c"}
      assert Inspect.parse(%{"inspect" => "bogus:x"}) == nil
      assert Inspect.parse(%{"inspect" => "relay:"}) == nil
      assert Inspect.parse(%{}) == nil
      # A host names the kinds it inspects; any other is not a selection there.
      assert Inspect.parse(%{"inspect" => "relay:orders"}, ~w(entry)) == nil
    end

    test "patches the selection into the query, keeping the rest, and clears it" do
      s = socket(%{current_path: "/relays", current_query: %{"health" => "failed"}})

      assert Inspect.inspect_path(s, {"relay", "default/orders"}) ==
               "/relays?health=failed&inspect=relay%3Adefault%2Forders"

      s = socket(%{current_path: "/relays", current_query: %{"inspect" => "relay:x"}})
      assert Inspect.inspect_path(s, nil) == "/relays"
    end
  end
end
