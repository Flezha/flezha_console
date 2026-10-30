defmodule FlezhaConsole.ControllerShapes do
  @moduledoc """
  The shapes of the controller's answers to the published reads the console
  makes: tuple tags, map keys and value types, never values.

  `priv/dev/record_shapes.exs` records them from the dev controller into
  `test/support/fixtures/controller_shapes.json`, and checks a live stack
  against that file; `FakeController`'s answers are checked against it in
  ExUnit. Plain Elixir with no dependency on the application, so the recorder
  can load it into a bare node.

  A shape is JSON: `"string"`, `"integer"`, `"float"`, `"boolean"`, `"atom"`,
  `"nil"`, `"pid"`, `"ref"`, `"fun"`, `{"tag": "ok" | "error"}` for a tuple's
  leading `:ok` or `:error`, `{"tuple": [...]}`, `{"list": shape | "empty"}`,
  `{"record": {key: shape}, "optional": [key]}` for a map keyed by atoms,
  `{"dict": shape}` for a map keyed by data, and `{"union": [...]}` where
  list elements disagree.
  """

  @doc """
  The reads recorded, as `{label, module, function, args}`; the caller context
  is appended to `args`. Each runs against what the dev stack seeds.
  """
  def reads do
    [
      {"Relay.list_namespaces", Flezha.Service.Relay, :list_namespaces, []},
      {"Relay.list", Flezha.Service.Relay, :list, ["default"]},
      {"Relay.list page", Flezha.Service.Relay, :list,
       ["default", [limit: 2, sort: :severity, filter: [health: ["unhealthy", "suspended"]]]]},
      {"Relay.list ids", Flezha.Service.Relay, :list,
       ["default", [filter: [ids: ["testnet_store_1"]]]]},
      {"Relay.list totals", Flezha.Service.Relay, :list, ["default", [limit: 0]]},
      {"Relay.overwatch_state", Flezha.Service.Relay, :overwatch_state,
       ["default", "testnet_store_1"]},
      {"Relay.graph", Flezha.Service.Relay, :graph, ["default", "testnet_store_1"]},
      {"Relay.activity", Flezha.Service.Relay, :activity, ["default", "testnet_store_1", []]},
      {"Relay.activity cells_of", Flezha.Service.Relay, :activity,
       ["default", "testnet_chain", [cells_of: "static_entry_tasklet", limit: 50]]},
      {"Relay.relay_plugins", Flezha.Service.Relay, :relay_plugins, ["default"]},
      {"Fleet.runners", Flezha.Service.Fleet, :runners, ["default"]},
      {"Fleet.factories", Flezha.Service.Fleet, :factories, ["default"]},
      {"Fleet.factory", Flezha.Service.Fleet, :factory, ["default", "chat_loop_steps"]},
      {"Fleet.runners_for_factory", Flezha.Service.Fleet, :runners_for_factory,
       ["default", "store_input"]},
      {"Fleet.providers", Flezha.Service.Fleet, :providers, []},
      {"Fleet.provider", Flezha.Service.Fleet, :provider, ["relay_http_push"]},
      {"Fleet.installed_plugins", Flezha.Service.Fleet, :installed_plugins, []},
      {"Namespace.list", Flezha.Service.Namespace, :list, []},
      {"Namespace.quota_kinds", Flezha.Service.Namespace, :quota_kinds, []},
      {"Namespace.quota", Flezha.Service.Namespace, :quota, ["default", :relays]},
      {"Namespace.roles", Flezha.Service.Namespace, :roles, ["default"]},
      {"Namespace.whoami", Flezha.Service.Namespace, :whoami, []},
      {"Dlq.list", Flezha.Service.Dlq, :list, [nil]},
      {"Dlq.list page", Flezha.Service.Dlq, :list, [nil, [limit: 2]]},
      {"Dlq.stats", Flezha.Service.Dlq, :stats, []},
      {"PluginManager.enabled page", Flezha.Service.PluginManager, :enabled,
       ["default", [limit: 2, filter: [text: "a"]]]},
      {"Steps.cells page", Flezha.Service.Steps, :cells, ["orders", [limit: 2]]},
      {"Steps.journal page", Flezha.Service.Steps, :journal, ["orders", [limit: 2]]},
      {"Steps.committed_iterations page", Flezha.Service.Steps, :committed_iterations,
       ["orders", [limit: 2]]},
      {"Steps.undelivered total", Flezha.Service.Steps, :undelivered, ["orders", [limit: 0]]},
      {"Schedule.list", Flezha.Service.Schedule, :list, []},
      {"Observability.list_sources", Flezha.Service.Observability, :list_sources, []},
      {"Observability.list_sinks", Flezha.Service.Observability, :list_sinks, []},
      {"Observability.query", Flezha.Service.Observability, :query,
       [%{source: :flezha_relay, limit: 20}]},
      {"Controller.status", Flezha.Service.Controller, :status, []},
      {"Controller.boot_status", Flezha.Service.Controller, :boot_status, []},
      {"Controller.cluster_status", Flezha.Service.Controller, :cluster_status, ["default"]},
      {"Controller.controllers", Flezha.Service.Controller, :controllers, []},
      {"Controller.durability_breaches", Flezha.Service.Controller, :durability_breaches, []},
      {"Controller.durability_status", Flezha.Service.Controller, :durability_status, []},
      {"Controller.mem_top", Flezha.Service.Controller, :mem_top, []},
      {"Controller.liveness_counters", Flezha.Service.Controller, :liveness_counters, []},
      {"Controller.liveness_counters relays", Flezha.Service.Controller, :liveness_counters,
       [[filter: [relays: [{"default", "testnet_store_1"}]]]]},
      {"Controller.liveness_counters totals", Flezha.Service.Controller, :liveness_counters,
       [[filter: [namespace: "default"], limit: 0]]},
      {"Logs.kinds", Flezha.Service.Logs, :kinds, []},
      {"Logs.read", Flezha.Service.Logs, :read, [[kind: "relay_history", limit: 20]]},
      {"Logs.files", Flezha.Service.Logs, :files, [[kind: "relay_history"]]},
      {"Logs.stats", Flezha.Service.Logs, :stats, [[kind: "relay_history"]]}
    ]
  end

  # Keys whose map is keyed by data rather than by fields: the hooks a relay's
  # bindings use, one count per health verdict or recent signal, and one value
  # per controller. Which keys such a map holds depends on what the stack runs.
  @keyed_by_data ~w(chains request_subs relay_health health signals statuses by_node refused)

  # Keys holding free-form data the console reads no field of: a relay's start
  # options, a plugin's configured options and the options its provider runs
  # with, which differ by provider, and an observability record's metadata and
  # measurements, which differ by event. Which entries they hold, and of what
  # type, depends on what the stack runs, so only their presence is kept.
  @free_form ~w(opts provider_opts metadata measurements)

  @doc "The shape of `term`."
  def of(term) when is_binary(term), do: "string"
  def of(term) when is_integer(term), do: "integer"
  def of(term) when is_float(term), do: "float"
  def of(term) when is_boolean(term), do: "boolean"
  def of(nil), do: "nil"
  def of(term) when term in [:ok, :error], do: %{"tag" => Atom.to_string(term)}
  def of(term) when is_atom(term), do: "atom"
  def of(term) when is_pid(term), do: "pid"
  def of(term) when is_reference(term), do: "ref"
  def of(term) when is_function(term), do: "fun"
  def of(term) when is_tuple(term), do: %{"tuple" => term |> Tuple.to_list() |> Enum.map(&of/1)}
  def of([]), do: %{"list" => "empty"}

  def of(term) when is_list(term),
    do: %{"list" => term |> Enum.map(&of/1) |> Enum.reduce(&merge/2)}

  def of(%_{} = term), do: term |> Map.from_struct() |> of()

  def of(term) when is_map(term) do
    if map_size(term) > 0 and Enum.all?(Map.keys(term), &is_atom/1),
      do: %{"record" => Map.new(term, &field/1), "optional" => []},
      else: dict(term)
  end

  defp dict(term) do
    case Map.values(term) do
      [] -> %{"dict" => "empty"}
      values -> %{"dict" => values |> Enum.map(&of/1) |> Enum.reduce(&merge/2)}
    end
  end

  defp field({key, value}), do: field(Atom.to_string(key), value)

  defp field(key, _value) when key in @free_form, do: {key, "data"}

  # Its keys are data, so none is read as a field name, even one that is
  # spelled like a data-keyed field.
  defp field(key, value) when key in @keyed_by_data and is_map(value) and not is_struct(value),
    do: {key, dict(value)}

  defp field(key, value), do: {key, of(value)}

  @doc "One shape covering both: what a list of `a` and `b` holds."
  def merge(same, same), do: same
  def merge("nil", other), do: other
  def merge(other, "nil"), do: other
  def merge(%{"list" => "empty"}, %{"list" => _} = other), do: other
  def merge(%{"list" => _} = other, %{"list" => "empty"}), do: other
  def merge(%{"list" => a}, %{"list" => b}), do: %{"list" => merge(a, b)}
  def merge(%{"dict" => "empty"}, %{"dict" => _} = other), do: other
  def merge(%{"dict" => _} = other, %{"dict" => "empty"}), do: other
  def merge(%{"dict" => a}, %{"dict" => b}), do: %{"dict" => merge(a, b)}

  def merge(%{"record" => a, "optional" => oa}, %{"record" => b, "optional" => ob}) do
    keys = Enum.uniq(Map.keys(a) ++ Map.keys(b))
    only_one = for k <- keys, not (Map.has_key?(a, k) and Map.has_key?(b, k)), do: k

    %{
      "record" => Map.new(keys, &{&1, merge_present(Map.get(a, &1), Map.get(b, &1))}),
      "optional" => Enum.sort(Enum.uniq(oa ++ ob ++ only_one))
    }
  end

  def merge(%{"tuple" => a}, %{"tuple" => b}) when length(a) == length(b),
    do: %{"tuple" => Enum.zip_with(a, b, &merge/2)}

  def merge(a, b), do: %{"union" => Enum.sort(Enum.uniq(alternatives(a) ++ alternatives(b)))}

  defp merge_present(nil, b), do: b
  defp merge_present(a, nil), do: a
  defp merge_present(a, b), do: merge(a, b)

  defp alternatives(%{"union" => list}), do: list
  defp alternatives(shape), do: [shape]

  @doc """
  Where `candidate` does not fit `recorded`, as `"path: what"` lines.

  A map key the recording always carries must be there, and a key it never
  carries must not be. `nil` fits any type, an empty list or map fits any
  list or map, a value fits a union holding its shape, and a union fits when
  each of its alternatives does.
  """
  def diff(recorded, candidate, path \\ "")

  def diff(same, same, _path), do: []
  def diff(_recorded, "nil", _path), do: []
  def diff("nil", _candidate, _path), do: []
  def diff(%{"list" => _}, %{"list" => "empty"}, _path), do: []
  def diff(%{"list" => "empty"}, %{"list" => _}, _path), do: []
  def diff(%{"list" => r}, %{"list" => c}, path), do: diff(r, c, path <> "[]")
  def diff(%{"dict" => _}, %{"dict" => "empty"}, _path), do: []
  def diff(%{"record" => _}, %{"dict" => "empty"}, _path), do: []
  def diff(%{"dict" => "empty"}, %{"dict" => _}, _path), do: []
  def diff(%{"dict" => r}, %{"dict" => c}, path), do: diff(r, c, path <> "{}")

  def diff(%{"record" => r, "optional" => optional}, %{"record" => c}, path) do
    missing =
      for k <- Map.keys(r), k not in optional, not Map.has_key?(c, k), do: "#{path}.#{k}: missing"

    unknown = for k <- Map.keys(c), not Map.has_key?(r, k), do: "#{path}.#{k}: not in the answer"

    shared =
      for k <- Map.keys(c), Map.has_key?(r, k), line <- diff(r[k], c[k], "#{path}.#{k}"), do: line

    missing ++ unknown ++ shared
  end

  def diff(%{"tuple" => r}, %{"tuple" => c}, path) when length(r) == length(c) do
    r
    |> Enum.zip(c)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{a, b}, i} -> diff(a, b, "#{path}{#{i}}") end)
  end

  def diff(recorded, %{"union" => alternatives}, path),
    do: alternatives |> Enum.flat_map(&diff(recorded, &1, path)) |> Enum.uniq()

  def diff(%{"union" => alternatives} = recorded, candidate, path) do
    if Enum.any?(alternatives, &(diff(&1, candidate, path) == [])),
      do: [],
      else: ["#{path}: #{describe(candidate)}, the answer is #{describe(recorded)}"]
  end

  def diff(recorded, candidate, path),
    do: ["#{path}: #{describe(candidate)}, the answer is #{describe(recorded)}"]

  defp describe(shape) when is_binary(shape), do: shape
  defp describe(%{"tag" => tag}), do: ":#{tag}"
  defp describe(%{"tuple" => items}), do: "a #{length(items)}-tuple"
  defp describe(%{"list" => _}), do: "a list"
  defp describe(%{"record" => _}), do: "a map with atom keys"
  defp describe(%{"dict" => _}), do: "a map keyed by data"
  defp describe(%{"union" => list}), do: Enum.map_join(list, " or ", &describe/1)

  @doc "The recording as committed: one read per line, every key sorted."
  def encode(by_label) do
    lines =
      by_label
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {label, shape} ->
        "  #{JSON.encode!(label)}: #{canonical(shape)}"
      end)

    "{\n" <> lines <> "\n}\n"
  end

  defp canonical(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort()
      |> Enum.map_join(",", fn {k, v} -> "#{JSON.encode!(k)}:#{canonical(v)}" end)

    "{" <> pairs <> "}"
  end

  defp canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"

  defp canonical(scalar), do: JSON.encode!(scalar)

  @doc "The recorded shape at `path`, a list of keys and `:each` for a list element."
  def at(shape, []), do: shape
  def at(%{"list" => element}, [:each | rest]), do: at(element, rest)

  def at(%{"tuple" => items}, [index | rest]) when is_integer(index),
    do: at(Enum.at(items, index), rest)

  def at(%{"record" => record}, [key | rest]), do: at(Map.fetch!(record, key), rest)
  def at(%{"dict" => value}, [:each | rest]), do: at(value, rest)
end
