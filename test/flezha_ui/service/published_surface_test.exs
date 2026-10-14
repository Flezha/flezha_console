defmodule FlezhaUi.Service.PublishedSurfaceTest do
  @moduledoc """
  The console and its fake controller stay on core's published consumer API
  and on core's error catalogue.

  Read from a core checkout rather than copied: core's own extractor
  (`scripts/consumer_surface.py`) finds the calls this checkout makes, and
  core's `docs/api/consumers/published.txt` says which functions a consumer may
  call. The reverse — every recorded call resolving in core — is core's own
  `consumer_surface_test.exs`.
  """

  use ExUnit.Case, async: true

  # Read before a context exists, because their answers are what a context is
  # built from. Nothing else may be called without one.
  @context_free ["Flezha.AuthZ.TokenStore.verify/1", "Flezha.AuthZ.enforcement_posture/0"]

  setup_all do
    core = System.get_env("FLEZHA_CORE_PATH") || Path.expand("../flezha", File.cwd!())
    published_path = Path.join(core, "docs/api/consumers/published.txt")
    extractor = Path.join(core, "scripts/consumer_surface.py")

    unless File.regular?(published_path) and File.regular?(extractor) do
      flunk(
        "no flezha core checkout at #{core} (looked for #{published_path} and #{extractor}); " <>
          "check it out beside this repository or set FLEZHA_CORE_PATH"
      )
    end

    {out, 0} = System.cmd("python3", [extractor, File.cwd!()])
    catalogue = core |> Path.join("flz_transport/errors.json") |> File.read!() |> Jason.decode!()

    %{
      allowed: MapSet.new(names(File.read!(published_path)) ++ @context_free),
      calls: MapSet.new(names(out)),
      stubs: stubs(),
      classes: Map.new(catalogue["codes"], fn {code, entry} -> {code, entry["class"]} end)
    }
  end

  test "every error the fake answers has the code and class core's catalogue gives it", %{
    classes: classes
  } do
    drift =
      for {code, class} <- Flezha.Error.classes(),
          Map.get(classes, code) != Atom.to_string(class),
          do: {code, class, Map.get(classes, code, :not_in_core)}

    assert drift == [], "fake class vs core class: #{inspect(drift)}"
  end

  test "the extractor finds the console's calls", %{calls: calls} do
    assert MapSet.size(calls) > 50
  end

  test "every call the console makes is published or context-free", %{
    calls: calls,
    allowed: allowed
  } do
    assert MapSet.difference(calls, allowed) |> Enum.sort() == []
  end

  test "every stub the fake defines is published at its arity", %{stubs: stubs, allowed: allowed} do
    assert MapSet.difference(stubs, allowed) |> Enum.sort() == []
  end

  test "every call the console makes has a stub", %{calls: calls, stubs: stubs} do
    assert MapSet.difference(calls, stubs) |> Enum.sort() == []
  end

  # `Module.function/arity` at the start of a line; comments and the rest of
  # the line are ignored.
  defp names(text) do
    for line <- String.split(text, "\n"),
        [name] <- [Regex.run(~r/^Flezha(?:\.\w+)+\.\w+[?!]?\/\d+/, line)],
        do: name
  end

  defp stubs do
    for module <- FakeController.modules(),
        module not in [FakeController, Flezha.Error],
        {function, arity} <- module.__info__(:functions),
        into: MapSet.new(),
        do: "#{inspect(module)}.#{function}/#{arity}"
  end
end
