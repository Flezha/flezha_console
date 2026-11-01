defmodule FlezhaConsole.Service.ControllerShapes do
  @moduledoc """
  The shapes of the controller's answers and stream events: tuple tags, map
  keys and value types, never values. They are the schema `NodeManager`
  decodes the channel's JSON with, and what `FakeController`'s answers are
  checked against in ExUnit.

  `priv/dev/record_shapes.exs` records them from the dev controller into
  `priv/controller_shapes.json`, and checks a live stack against that file.
  `of/1`, `merge/2` and `diff/3` are plain Elixir with no dependency on the
  application, so the recorder can load this file into a bare node.

  A shape is JSON: `"string"`, `"integer"`, `"float"`, `"boolean"`, `"atom"`,
  `"nil"`, `"pid"`, `"ref"`, `"fun"`, `"node"` for a node's name, which is
  always read as text, `"datetime"`, `"data"` for free-form data, `{"tag":
  "ok" | "error"}` for a tuple's leading `:ok` or `:error`, `{"tuple": [...]}`,
  `{"list": shape | "empty"}`, `{"record": {key: shape}, "optional": [key]}`
  for a map keyed by atoms, `{"dict": shape}` for a map keyed by data, with
  `"atoms": "all"` for one keyed by atoms that are data, such as health
  verdicts, or `"atoms": [key]` naming the atom keys of one that mixes them
  with text keys, and `{"union": [...]}` where list elements disagree.

  A recording is labelled by its operation, `"Relay.list"`, followed by a
  word naming the variant (`"Relay.list page"`), and a stream event by its
  operation and the event's name (`"Relay.listen event output"`).
  """

  @doc """
  The reads recorded, as `{label, module, function, args}`; the caller context
  is appended to `args`. Each runs against what the dev stack seeds, and the
  `shapes_recorder` relays the recorder starts first.
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
      {"Relay.list group page", Flezha.Service.Relay, :list,
       ["default", [limit: 5, filter: [group: "shapes_recorder_parts"]]]},
      {"Relay.list member", Flezha.Service.Relay, :list,
       ["default", [filter: [ids: ["shapes_recorder_parts#p0", "shapes_recorder_parts"]]]]},
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
      {"Fleet.provider websocket", Flezha.Service.Fleet, :provider, ["relay_websocket"]},
      {"Fleet.provider http_poll", Flezha.Service.Fleet, :provider, ["relay_http_poll"]},
      {"Fleet.provider webhook", Flezha.Service.Fleet, :provider, ["hook_webhook"]},
      {"Fleet.provider io_filter", Flezha.Service.Fleet, :provider, ["relay_io_filter"]},
      {"Fleet.provider file_output", Flezha.Service.Fleet, :provider, ["relay_file_output"]},
      {"Fleet.installed_plugins", Flezha.Service.Fleet, :installed_plugins, []},
      {"Namespace.list", Flezha.Service.Namespace, :list, []},
      {"Namespace.quota_kinds", Flezha.Service.Namespace, :quota_kinds, []},
      {"Namespace.quota", Flezha.Service.Namespace, :quota, ["default", :relays]},
      {"Namespace.roles", Flezha.Service.Namespace, :roles, ["default"]},
      {"Namespace.whoami", Flezha.Service.Namespace, :whoami, []},
      {"Dlq.list", Flezha.Service.Dlq, :list, [nil]},
      {"Dlq.list page", Flezha.Service.Dlq, :list, [nil, [limit: 2]]},
      {"Dlq.stats", Flezha.Service.Dlq, :stats, []},
      {"PluginManager.enabled", Flezha.Service.PluginManager, :enabled, ["default"]},
      {"PluginManager.enabled page", Flezha.Service.PluginManager, :enabled,
       ["default", [limit: 2, filter: [text: "a"]]]},
      {"Steps.cells", Flezha.Service.Steps, :cells, ["shapes_recorder_chat"]},
      {"Steps.cells page", Flezha.Service.Steps, :cells, ["shapes_recorder_chat", [limit: 2]]},
      {"Steps.journal", Flezha.Service.Steps, :journal, ["shapes_recorder_chat"]},
      {"Steps.journal page", Flezha.Service.Steps, :journal,
       ["shapes_recorder_chat", [limit: 2]]},
      {"Steps.committed_iterations", Flezha.Service.Steps, :committed_iterations,
       ["shapes_recorder_chat"]},
      {"Steps.committed_iterations page", Flezha.Service.Steps, :committed_iterations,
       ["shapes_recorder_chat", [limit: 2]]},
      {"Steps.undelivered", Flezha.Service.Steps, :undelivered, ["shapes_recorder_chat"]},
      {"Steps.undelivered total", Flezha.Service.Steps, :undelivered,
       ["shapes_recorder_chat", [limit: 0]]},
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

  # A node's name and a time cross the channel as text.
  @as_text ~w(node datetime)

  @doc "The shape of `term`."
  def of(term) when is_binary(term), do: "string"
  def of(term) when is_integer(term), do: "integer"
  def of(term) when is_float(term), do: "float"
  def of(term) when is_boolean(term), do: "boolean"
  def of(nil), do: "nil"
  def of(%DateTime{}), do: "datetime"
  def of(term) when term in [:ok, :error], do: %{"tag" => Atom.to_string(term)}

  def of(term) when is_atom(term),
    do: if(String.contains?(Atom.to_string(term), "@"), do: "node", else: "atom")

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
    shape =
      case Map.values(term) do
        [] -> %{"dict" => "empty"}
        values -> %{"dict" => values |> Enum.map(&of/1) |> Enum.reduce(&merge/2)}
      end

    case Enum.split_with(Map.keys(term), &(of(&1) == "atom")) do
      {[], _text} ->
        shape

      {_atoms, []} ->
        Map.put(shape, "atoms", "all")

      {atoms, _text} ->
        Map.put(shape, "atoms", atoms |> Enum.map(&Atom.to_string/1) |> Enum.sort())
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
  def merge(text, "string") when text in @as_text, do: text
  def merge("string", text) when text in @as_text, do: text
  def merge("nil", other), do: other
  def merge(other, "nil"), do: other
  def merge(%{"list" => "empty"}, %{"list" => _} = other), do: other
  def merge(%{"list" => _} = other, %{"list" => "empty"}), do: other
  def merge(%{"list" => a}, %{"list" => b}), do: %{"list" => merge(a, b)}

  def merge(%{"dict" => a} = x, %{"dict" => b} = y) do
    value =
      case {a, b} do
        {"empty", other} -> other
        {other, "empty"} -> other
        {a, b} -> merge(a, b)
      end

    case merge_atoms(x["atoms"], y["atoms"]) do
      nil -> %{"dict" => value}
      atoms -> %{"dict" => value, "atoms" => atoms}
    end
  end

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

  # A dict keyed only by atoms stays so only while every recording agrees.
  defp merge_atoms(same, same), do: same
  defp merge_atoms(nil, atoms), do: atoms
  defp merge_atoms(atoms, nil), do: atoms
  defp merge_atoms("all", atoms), do: atoms
  defp merge_atoms(atoms, "all"), do: atoms
  defp merge_atoms(a, b), do: Enum.sort(Enum.uniq(a ++ b))

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

  def diff(text, "string", _path) when text in @as_text, do: []
  def diff("string", text, _path) when text in @as_text, do: []

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

  # ---- Decoding ----

  @key {__MODULE__, :schema}

  @doc """
  Loads the shipped recording, so `answer/2` and `event/3` decode with it.
  Called once at boot; the file is read again only by another `load/1`.
  """
  def load(path \\ Application.app_dir(:flezha_console, "priv/controller_shapes.json")) do
    by_label = path |> File.read!() |> JSON.decode!()

    schema =
      by_label
      |> Enum.group_by(fn {label, _shape} -> label_key(label) end, fn {_label, shape} -> shape end)
      |> Map.new(fn {key, shapes} -> {key, shapes |> Enum.reduce(&merge/2) |> compile()} end)

    :persistent_term.put(@key, schema)
    :ok
  end

  @doc "The operations and events the shipped recording holds a shape for, keyed by operation, or by `{operation, event}` for a stream event."
  def recorded, do: schema() |> Map.keys() |> Enum.sort()

  # The key a label is filed under: the operation, `"Relay.list"`, or for a
  # stream event `{"Relay.listen", "output"}`.
  defp label_key(label) do
    case String.split(label, " ") do
      [operation, "event", name | _] -> {operation, name}
      [operation | _variant] -> operation
    end
  end

  @doc """
  The value of a call's answer, decoded from the channel's JSON by the shape
  of `operation`'s answer: the value its `{:ok, value}` carries, a
  `{:ok, value, more}` as `[value, more]`, a bare `:ok` as `:ok`. An operation
  with no recorded shape is answered as the JSON came.
  """
  def answer(operation, json), do: decode(Map.get(schema(), operation, :data), json, :answer)

  @doc "A stream event of `operation` named `name`, in its term's JSON form, decoded by its shape."
  def event(operation, name, json), do: decode(Map.get(schema(), {operation, name}, :data), json)

  defp schema do
    case :persistent_term.get(@key, nil) do
      nil ->
        load()
        :persistent_term.get(@key)

      schema ->
        schema
    end
  end

  @doc """
  `json` decoded by the compiled `shape`. A record's keys become the atoms the
  shipped file names, an atom becomes an existing atom or stays text, a tuple
  becomes a tuple, a time becomes a `DateTime`, a binary that is not text
  arrives as `{"base64": ...}` and becomes bytes. Free-form data, a value the
  recording only saw as `nil` or as an empty collection, and a key the
  recording does not name are read as core flattened their term: a key naming
  an existing atom becomes that atom, and a list of `[name, value]` pairs a
  keyword list. Nothing else is changed, so no atom is made from the
  controller's data.
  """
  def decode(shape, json)

  def decode(_shape, nil), do: nil
  def decode(:data, json), do: data(json)

  def decode(:string, %{"base64" => encoded} = json) when map_size(json) == 1,
    do: bytes(encoded, json)

  def decode(:atom, text) when is_binary(text), do: existing_atom(text)

  def decode(:datetime, text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _offset} -> time
      {:error, _invalid} -> text
    end
  end

  def decode({:tag, _tag}, text) when is_binary(text), do: existing_atom(text)

  def decode({:tuple, shapes}, list) when is_list(list) and length(list) == length(shapes),
    do: shapes |> Enum.zip_with(list, &decode/2) |> List.to_tuple()

  def decode({:list, shape}, list) when is_list(list), do: Enum.map(list, &decode(shape, &1))

  def decode({:record, fields}, map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      case fields do
        %{^key => {atom, shape}} -> {atom, decode(shape, value)}
        %{} -> {existing_atom(key), data(value)}
      end
    end)
  end

  def decode({:dict, shape, atoms}, map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {dict_key(atoms, key), decode(shape, value)} end)

  def decode({:union, alternatives}, json) do
    case Enum.find(alternatives, &fits?(&1, json)) do
      nil -> json
      shape -> decode(shape, json)
    end
  end

  def decode(_shape, json), do: json

  defp data(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {existing_atom(key), data(value)} end)

  defp data([_ | _] = list) do
    if Enum.all?(list, &pair?/1),
      do: Enum.map(list, fn [key, value] -> {existing_atom(key), data(value)} end),
      else: Enum.map(list, &data/1)
  end

  defp data(json), do: json

  defp pair?([key, _value]) when is_binary(key), do: is_atom(existing_atom(key))
  defp pair?(_element), do: false

  # An operation's answer is the value inside its `{:ok, ...}`.
  defp decode({:union, alternatives}, json, :answer) do
    case Enum.find(alternatives, &ok?/1) do
      nil -> decode({:union, alternatives}, json)
      shape -> decode(shape, json, :answer)
    end
  end

  defp decode({:tuple, [{:tag, :ok}, value]}, json, :answer), do: decode(value, json)

  defp decode({:tuple, [{:tag, :ok} | values]}, json, :answer),
    do: decode({:tuple, values}, json) |> tuple_list()

  defp decode(shape, json, :answer), do: decode(shape, json)

  defp tuple_list(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)
  defp tuple_list(other), do: other

  defp ok?({:tuple, [{:tag, :ok} | _]}), do: true
  defp ok?({:tag, :ok}), do: true
  defp ok?(_shape), do: false

  # Which alternative of a union a JSON value is: text stays text where the
  # union also allows text, and a list is a tuple only of the tuple's length.
  defp fits?(shape, json) when is_binary(json),
    do: shape in [:string, :atom, :node, :datetime, :pid, :ref, :fun] or match?({:tag, _}, shape)

  defp fits?(shape, json) when is_boolean(json), do: shape == :boolean
  defp fits?(shape, json) when is_integer(json), do: shape in [:integer, :float]
  defp fits?(shape, json) when is_float(json), do: shape == :float
  defp fits?({:tuple, shapes}, json) when is_list(json), do: length(shapes) == length(json)
  defp fits?({:list, _shape}, json) when is_list(json), do: true
  defp fits?({:record, _fields}, json) when is_map(json), do: true
  defp fits?({:dict, _shape, _atoms}, json) when is_map(json), do: true
  defp fits?(_shape, _json), do: false

  defp dict_key(:none, key), do: key
  defp dict_key(:all, key), do: existing_atom(key)
  defp dict_key(atoms, key), do: if(MapSet.member?(atoms, key), do: existing_atom(key), else: key)

  defp existing_atom(text) do
    String.to_existing_atom(text)
  rescue
    ArgumentError -> text
  end

  defp bytes(encoded, json) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> bytes
      :error -> json
    end
  end

  @doc """
  A recorded shape in the form `decode/2` walks: a record's keys paired with
  their atoms, made from the recording and never from the controller's data,
  and a union's alternatives ordered so text is preferred over an atom.
  """
  def compile(name) when name in ["data", "empty", "nil"], do: :data
  def compile(name) when is_binary(name), do: String.to_atom(name)
  def compile(%{"tag" => tag}), do: {:tag, String.to_atom(tag)}
  def compile(%{"tuple" => shapes}), do: {:tuple, Enum.map(shapes, &compile/1)}
  def compile(%{"list" => shape}), do: {:list, compile(shape)}

  def compile(%{"dict" => shape} = dict) do
    atoms =
      case dict do
        %{"atoms" => "all"} -> :all
        %{"atoms" => atoms} -> MapSet.new(atoms)
        %{} -> :none
      end

    {:dict, compile(shape), atoms}
  end

  def compile(%{"record" => fields}),
    do:
      {:record,
       Map.new(fields, fn {key, shape} -> {key, {String.to_atom(key), compile(shape)}} end)}

  def compile(%{"union" => shapes}),
    do: {:union, shapes |> Enum.map(&compile/1) |> Enum.sort_by(&(&1 == :atom))}
end
