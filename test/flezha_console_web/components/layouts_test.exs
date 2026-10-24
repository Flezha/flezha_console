defmodule FlezhaConsoleWeb.LayoutsTest do
  @moduledoc """
  The shell's derivations from the route.

  Where the operator is — what the rail marks, the crumb trail, the screen
  kind help explains — where the namespace picker goes and where `/` lands are
  all functions of the path, so they are tested
  as functions, once, rather than through fourteen screens that each happen to
  render them.
  """

  use ExUnit.Case, async: true

  alias FlezhaConsoleWeb.Layouts

  @routes [
    "/relays",
    "/plugins",
    "/schedules",
    "/problems",
    "/dlq",
    "/namespaces",
    "/cluster",
    "/controller",
    "/observability",
    "/audit",
    "/namespaces/default",
    "/namespaces/default/relays",
    "/namespaces/default/plugins",
    "/namespaces/default/schedules",
    "/namespaces/default/relays/relay_a",
    "/namespaces/default/relays/relay_a/listen",
    "/namespaces/default/relays/relay_a/state"
  ]

  describe "longpoll_fallback/1" do
    import Phoenix.LiveViewTest

    test "hands app.js the threshold, or nothing, and the page keeps its websocket" do
      assert render_component(&Layouts.longpoll_fallback/1, ms: 2_500) =~
               ~s(<meta name="longpoll-fallback-ms" content="2500">)

      assert render_component(&Layouts.longpoll_fallback/1, ms: nil) == ""
    end
  end

  describe "breadcrumbs/1" do
    test "a rail destination carries no trail" do
      for path <- [
            "/",
            "/namespaces",
            "/relays",
            "/cluster",
            "/namespaces/default",
            "/namespaces/default/relays"
          ] do
        assert Layouts.breadcrumbs(path) == [], "#{path} has a trail"
      end
    end

    test "a relay's state names the namespace, Relays, the relay and the view" do
      trail = Layouts.breadcrumbs("/namespaces/default/relays/relay_a/state")

      assert Enum.map(trail, & &1.label) == ["default", "Relays", "relay_a", "State"]

      # Every ancestor navigates; the page being read does not link to itself.
      assert Enum.map(trail, & &1.path) == [
               "/namespaces/default",
               "/namespaces/default/relays",
               "/namespaces/default/relays/relay_a",
               nil
             ]
    end

    test "the relay's Live view is the last crumb itself" do
      assert %{label: "relay_a", path: nil} =
               List.last(Layouts.breadcrumbs("/namespaces/default/relays/relay_a"))
    end

    test "the listen view's last crumb reads Listen" do
      trail = Layouts.breadcrumbs("/namespaces/default/relays/relay_a/listen")

      assert %{label: "Listen", path: nil} = List.last(trail)
    end

    test "a namespace spelled like a screen keeps its own name" do
      assert [%{label: "relays"} | _] = Layouts.breadcrumbs("/namespaces/relays/relays/x")
    end

    test "an encoded relay id is named as the relay calls itself" do
      assert [_ns, _relays, %{label: "demo#p0", path: nil}] =
               Layouts.breadcrumbs("/namespaces/default/relays/demo%23p0")
    end
  end

  describe "nav_current?/2" do
    test "a platform screen owns its subtree" do
      assert Layouts.nav_current?("/dlq/some-class", "/dlq")
    end

    test "a subtree is measured in segments, not in characters" do
      refute Layouts.nav_current?("/relays-elsewhere", "/relays")
    end

    test "a scoped route marks its own entry, not the platform twin" do
      current = "/namespaces/default/relays"

      assert Layouts.nav_current?(current, "/namespaces/default/relays")
      refute Layouts.nav_current?(current, "/relays")
      refute Layouts.nav_current?(current, "/namespaces")
      refute Layouts.nav_current?(current, "/namespaces/default")
    end

    test "a relay below a collection marks the collection" do
      current = "/namespaces/default/relays/relay_a/listen"

      assert Layouts.nav_current?(current, "/namespaces/default/relays")
      refute Layouts.nav_current?(current, "/namespaces/default")
    end

    test "another namespace's entry is never current" do
      refute Layouts.nav_current?("/namespaces/default/plugins", "/namespaces/other/plugins")
    end

    # The all-namespaces relays, plugins and schedules are reached by a
    # screen's scope switch, not from the rail.
    test "exactly one rail entry is current on every route" do
      for path <- @routes -- ["/relays", "/plugins", "/schedules"] do
        marked =
          for section <- Layouts.nav_sections("default"),
              entry <- section.entries,
              Layouts.nav_current?(path, entry.path),
              do: entry.path

        assert length(marked) == 1, "#{path} marked #{inspect(marked)}"
      end
    end
  end

  describe "nav_sections/1" do
    test "the rail is the namespace, then attention, the platform and monitoring" do
      assert [
               %{heading: "Namespace"},
               %{heading: "Attention", scope: nil},
               %{heading: "Platform", scope: nil},
               %{heading: "Monitoring", scope: nil}
             ] = Layouts.nav_sections("default")
    end

    test "the namespace group is empty until a namespace is in force" do
      assert [%{heading: "Namespace", scope: nil, entries: []} | _rest] =
               Layouts.nav_sections(nil)
    end

    test "the namespace group opens on Home, then Relays, Plugins and Schedules" do
      [scoped | _rest] = Layouts.nav_sections("default")

      assert scoped.scope == "default"
      assert Enum.map(scoped.entries, & &1.label) == ~w(Home Relays Plugins Schedules)

      assert Enum.map(scoped.entries, & &1.path) ==
               ~w(/namespaces/default /namespaces/default/relays /namespaces/default/plugins /namespaces/default/schedules)
    end

    test "attention, platform and monitoring group the platform screens by purpose" do
      [_scoped, attention, platform, monitoring] = Layouts.nav_sections("default")

      assert Enum.map(attention.entries, & &1.label) == ["Problems", "Dead-letter"]
      assert Enum.map(platform.entries, & &1.label) == ["Namespaces", "Cluster", "Controller"]
      assert Enum.map(monitoring.entries, & &1.label) == ["Observability", "Audit log"]
    end

    test "Problems alone carries the count, and every relay is no destination of its own" do
      entries = for section <- Layouts.nav_sections("default"), e <- section.entries, do: e

      assert [%{label: "Problems", path: "/problems"}] =
               Enum.filter(entries, &(&1.count == :problems))

      refute Enum.any?(entries, &(&1.path == "/relays" or &1.label == "Fleet"))
    end
  end

  describe "screen/1" do
    test "a relay's views name the screen help explains" do
      assert Layouts.screen("/namespaces/default/relays/relay_a") == :relay_live
      assert Layouts.screen("/namespaces/default/relays/relay_a/listen") == :relay_listen
      assert Layouts.screen("/namespaces/default/relays/relay_a/state") == :relay_state
      assert Layouts.screen("/namespaces/default") == :home
    end

    test "every routed screen kind has a help purpose" do
      for path <- @routes ++ ["/users/settings", "/dev/kit"] do
        kind = Layouts.screen(path)
        assert kind && FlezhaConsoleWeb.Glossary.screen(kind), "#{path} (#{kind}) has no purpose"
      end
    end
  end

  describe "scope_target/2" do
    test "a scoped collection keeps its screen kind under the new namespace" do
      assert Layouts.scope_target("/namespaces/a/relays", "b") == "/namespaces/b/relays"
      assert Layouts.scope_target("/namespaces/a/plugins", "b") == "/namespaces/b/plugins"
      assert Layouts.scope_target("/namespaces/a/schedules", "b") == "/namespaces/b/schedules"
    end

    test "Home, a platform screen and an all-namespaces form go to the namespace's Home" do
      for path <- ["/namespaces/a", "/cluster", "/problems", "/relays", "/plugins"] do
        assert Layouts.scope_target(path, "b") == "/namespaces/b", "from #{path}"
      end
    end

    test "one namespace's relay means nothing under another, so its relays" do
      assert Layouts.scope_target("/namespaces/a/relays/relay_a/listen", "b") ==
               "/namespaces/b/relays"
    end
  end

  describe "landing/2" do
    test "the namespace last worked in, then the first reachable, then the list" do
      assert Layouts.landing("billing", ["billing", "default"]) == "/namespaces/billing"
      assert Layouts.landing("gone", ["zeta", "default"]) == "/namespaces/default"
      assert Layouts.landing(nil, ["default"]) == "/namespaces/default"
      assert Layouts.landing("gone", []) == "/namespaces"
    end
  end

  describe "relay_tabs/3" do
    test "Live, Listen and State, each its own route, one current" do
      tabs = Layouts.relay_tabs("default", "relay_a", :state)

      assert Enum.map(tabs, & &1.label) == ~w(Live Listen State)

      assert Enum.map(tabs, & &1.path) ==
               ~w(/namespaces/default/relays/relay_a /namespaces/default/relays/relay_a/listen /namespaces/default/relays/relay_a/state)

      assert [%{label: "State"}] = Enum.filter(tabs, & &1.current?)
    end
  end
end
