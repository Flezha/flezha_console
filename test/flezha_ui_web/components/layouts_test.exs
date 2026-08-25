defmodule FlezhaUiWeb.LayoutsTest do
  @moduledoc """
  The shell's derivations from the route.

  Where the operator is, what the rail marks, and where the namespace picker
  goes are all functions of the path — so they are tested as functions, once,
  rather than through fourteen screens that each happen to render them.
  """

  use ExUnit.Case, async: true

  alias FlezhaUiWeb.Layouts

  describe "breadcrumbs/1" do
    test "a top-level screen carries no trail" do
      assert Layouts.breadcrumbs("/") == []
      assert Layouts.breadcrumbs("/namespaces") == []
      assert Layouts.breadcrumbs("/operatives") == []
    end

    test "a namespace names the collection above it" do
      assert Layouts.breadcrumbs("/namespaces/default") == [
               %{label: "Namespaces", path: "/namespaces"},
               %{label: "default", path: nil}
             ]
    end

    test "an operative's state names the namespace, the operative and the view" do
      trail = Layouts.breadcrumbs("/namespaces/default/operatives/op_a/state")

      assert Enum.map(trail, & &1.label) == [
               "Namespaces",
               "default",
               "Operatives",
               "op_a",
               "State"
             ]

      # Every ancestor navigates; the page being read does not link to itself.
      assert Enum.map(trail, & &1.path) == [
               "/namespaces",
               "/namespaces/default",
               "/namespaces/default/operatives",
               "/namespaces/default/operatives/op_a",
               nil
             ]
    end

    test "a namespace spelled like a screen keeps its own name" do
      trail = Layouts.breadcrumbs("/namespaces/operatives/plugins")

      assert Enum.map(trail, & &1.label) == ["Namespaces", "operatives", "Plugins"]
    end
  end

  describe "nav_current?/2" do
    test "the dashboard is an exact match" do
      assert Layouts.nav_current?("/", "/")
      refute Layouts.nav_current?("/cluster", "/")
    end

    test "a platform screen owns its subtree" do
      assert Layouts.nav_current?("/dlq/some-class", "/dlq")
    end

    test "a subtree is measured in segments, not in characters" do
      refute Layouts.nav_current?("/operatives-elsewhere", "/operatives")
    end

    test "a scoped route marks its own entry, not the platform twin" do
      current = "/namespaces/default/operatives"

      assert Layouts.nav_current?(current, "/namespaces/default/operatives")
      refute Layouts.nav_current?(current, "/operatives")
      refute Layouts.nav_current?(current, "/namespaces")
      refute Layouts.nav_current?(current, "/namespaces/default")
    end

    test "an operative below a collection marks the collection" do
      current = "/namespaces/default/operatives/op_a/stream"

      assert Layouts.nav_current?(current, "/namespaces/default/operatives")
      refute Layouts.nav_current?(current, "/namespaces/default")
    end

    test "another namespace's entry is never current" do
      refute Layouts.nav_current?("/namespaces/default/plugins", "/namespaces/other/plugins")
    end

    test "exactly one rail entry is current on every route" do
      paths = [
        "/",
        "/operatives",
        "/namespaces",
        "/cluster",
        "/controller",
        "/observability",
        "/dlq",
        "/audit",
        "/namespaces/default",
        "/namespaces/default/operatives",
        "/namespaces/default/plugins",
        "/namespaces/default/schedules",
        "/namespaces/default/operatives/op_a",
        "/namespaces/default/operatives/op_a/stream",
        "/namespaces/default/operatives/op_a/state"
      ]

      for path <- paths do
        marked =
          for section <- Layouts.nav_sections(Layouts.scoped_namespace(path)),
              entry <- section.entries,
              Layouts.nav_current?(path, entry.path),
              do: entry.path

        assert length(marked) == 1, "#{path} marked #{inspect(marked)}"
      end
    end
  end

  describe "nav_sections/1" do
    test "the rail is two labelled groups" do
      assert [%{heading: "Namespace"}, %{heading: "Platform", scope: nil}] =
               Layouts.nav_sections("default")
    end

    test "the scoped group is empty until a namespace is in force" do
      assert [%{heading: "Namespace", scope: nil, entries: []}, _platform] =
               Layouts.nav_sections(nil)
    end

    test "the scoped group holds only screens the controller can answer per namespace" do
      [scoped, _platform] = Layouts.nav_sections("default")

      assert scoped.scope == "default"
      assert Enum.map(scoped.entries, & &1.label) == ~w(Overview Operatives Plugins Schedules)
    end

    test "dead-letter and observability stay platform-global" do
      [_scoped, platform] = Layouts.nav_sections("default")
      labels = Enum.map(platform.entries, & &1.label)

      assert "Dead-letter" in labels
      assert "Observability" in labels
      assert "Fleet" in labels
    end
  end

  describe "scope_target/2" do
    test "a scoped collection keeps its screen kind under the new namespace" do
      assert Layouts.scope_target("/namespaces/a/operatives", "b") == "/namespaces/b/operatives"
      assert Layouts.scope_target("/namespaces/a/plugins", "b") == "/namespaces/b/plugins"
      assert Layouts.scope_target("/namespaces/a/schedules", "b") == "/namespaces/b/schedules"
    end

    test "a platform screen goes to the namespace's overview" do
      assert Layouts.scope_target("/cluster", "b") == "/namespaces/b"
      assert Layouts.scope_target("/", "b") == "/namespaces/b"
    end

    test "one namespace's operative means nothing under another, so the collection it is" do
      assert Layouts.scope_target("/namespaces/a/operatives/op_a/stream", "b") ==
               "/namespaces/b/operatives"
    end
  end
end
