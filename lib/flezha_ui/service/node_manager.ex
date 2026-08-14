defmodule FlezhaUi.Service.NodeManager do
  @moduledoc """
  The single seam between this UI and the flezha controller node.

  Every remote module name the UI depends on is declared here and nowhere else,
  so a controller API change is a one-file diff. Callers receive either the
  remote function's own reply or one of four normalised errors — never a raw
  `:erpc` exit:

    * `{:error, :node_not_connected}` — no controller node is reachable.
    * `{:error, {:api_missing, module, function, arity}}` — the controller does
      not export the call. This is the signal that UI and controller versions
      have diverged.
    * `{:error, :timeout}` — the controller did not answer in time.
    * `{:error, {:remote_error, term}}` — anything else that went wrong on the
      remote side.
  """

  require Logger

  @default_timeout 15_000

  def connected_node do
    Node.list(:connected) |> List.first()
  end

  @doc """
  Runs `module.function(args)` on the connected controller node.

  A remote reply of `{:error, reason}` is passed through untouched — it is the
  remote function's own answer, not a transport failure.
  """
  def erpc_call(module, function, args, timeout \\ @default_timeout) do
    case connected_node() do
      nil ->
        {:error, :node_not_connected}

      node ->
        try do
          :erpc.call(node, module, function, args, timeout)
        catch
          kind, reason -> classify(kind, reason, module, function, args)
        end
    end
  end

  # `:erpc.call/5` raises `ErlangError` wrapping `{:exception, :undef, stack}`
  # when the remote module or function does not exist. The head of that stack
  # names the entry point that was missing, which is exactly the version-skew
  # signal we want to surface.
  defp classify(:error, %ErlangError{original: {:exception, :undef, stack}}, m, f, args) do
    undef_error(stack, m, f, args)
  end

  defp classify(:error, {:exception, :undef, stack}, m, f, args) do
    undef_error(stack, m, f, args)
  end

  defp classify(:error, {:erpc, :timeout}, _m, _f, _args), do: {:error, :timeout}
  defp classify(:exit, {:erpc, :timeout}, _m, _f, _args), do: {:error, :timeout}
  defp classify(:error, {:erpc, :noconnection}, _m, _f, _args), do: {:error, :node_not_connected}
  defp classify(:exit, {:erpc, :noconnection}, _m, _f, _args), do: {:error, :node_not_connected}

  defp classify(_kind, reason, _m, _f, _args), do: {:error, {:remote_error, reason}}

  defp undef_error(stack, m, f, args) do
    {mod, fun, arity} =
      case stack do
        [{mod, fun, a, _} | _] when is_list(a) -> {mod, fun, length(a)}
        [{mod, fun, a, _} | _] when is_integer(a) -> {mod, fun, a}
        _ -> {m, f, length(args)}
      end

    Logger.warning(
      "[NodeManager] Controller does not export #{inspect(mod)}.#{fun}/#{arity} " <>
        "(called as #{inspect(m)}.#{f}/#{length(args)}). UI and controller versions have " <>
        "diverged. Remote stacktrace: #{inspect(stack)}"
    )

    {:error, {:api_missing, mod, fun, arity}}
  end

  @doc """
  Caller context for the controller's service APIs (`Flezha.Service.AuditLog`,
  `Flezha.Service.Observability`). `:principal` is omitted while the
  controller's authz subsystem is disabled; binding one later is a change to
  this function alone.
  """
  def caller_context(principal \\ nil) do
    case principal do
      nil -> %{source: :ui}
      p -> %{source: :ui, principal: p}
    end
  end

  @doc """
  Runs a call that answers a collection, normalised to `{:ok, list}`.

  The controller is inconsistent about this — some functions answer a bare list,
  others `{:ok, list}`. Flattening it here is the seam earning its keep: every
  caller writes one `case` instead of its own unwrapper.
  """
  def list_call(module, function, args) do
    case erpc_call(module, function, args) do
      {:ok, list} when is_list(list) -> {:ok, list}
      list when is_list(list) -> {:ok, list}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:remote_error, other}}
    end
  end

  @doc """
  The value out of a `list_call/3` result, or `default` when it failed.

  For a screen that shows a section as empty when the controller cannot answer
  it, rather than failing the whole page.
  """
  def ok_or({:ok, value}, _default), do: value
  def ok_or({:error, _reason}, default), do: default

  # ---- Namespace / Operative API ----

  def list_namespaces() do
    list_call(Flezha, :list_namespaces, [])
  end

  def list_operatives(namespace) do
    list_call(Flezha, :list_operatives, [namespace])
  end

  def list_runners(namespace) do
    list_call(Flezha, :list_runners, [namespace])
  end

  def list_factories(namespace) do
    list_call(Flezha, :list_factories, [namespace])
  end

  @doc """
  Starts an operative. The spec is a plain atom-keyed map: the controller
  reaches its fields with dot notation, so a `%Flezha.Operative.Builder{}`
  struct is not required on the wire.
  """
  def start_operative(namespace, id, factory_id, init_values \\ %{}, opts \\ [], kind \\ :stream) do
    operative = %{
      id: id,
      factory_id: factory_id,
      kind: kind,
      init_values: init_values,
      opts: opts
    }

    erpc_call(Flezha, :start_operative, [namespace, operative])
  end

  def stop_operative(namespace, operative_id) do
    erpc_call(Flezha, :stop_operative, [namespace, operative_id])
  end

  @doc """
  Entity state narrowed by `selector` — `%{procedure: name}` or
  `%{procedure: name, entity_key: key}`; `%{}` covers every Procedure.

  Answers `{:ok, json, change_seq}`, where `change_seq` is the sequence the
  state was serialised at and may be ahead of what is durable.
  """
  def entity_state(namespace, operative_id, selector) when is_map(selector) do
    erpc_call(Flezha.Service.OperativeManager, :get_entity_state, [
      namespace,
      operative_id,
      selector
    ])
  end

  def get_overwatch_state(namespace, operative_id) do
    erpc_call(Flezha.Service.OperativeManager, :get_overwatch_state, [namespace, operative_id])
  end

  # ---- Plugin API ----

  # Per-subscription options (`position`, `interval_ms`, ...) arrive prefixed so
  # they stay distinguishable from provider options of the same name.
  @sub_opt_prefix "sub_"

  # The host's extension points. Which of them a given provider exports, and
  # which options each accepts, is the controller's call — an unexported
  # extension is refused there and the refusal is shown to the operator.
  @extensions ~w(on_operative_init on_input on_output on_interval on_message
                 on_snapshot on_terminate)a

  # Per-subscription option names the host's validators recognise.
  @sub_opts ~w(position interval_ms key timeout_ms name)a

  @doc "The extension points a plugin may subscribe to."
  def extensions, do: @extensions

  @doc """
  Enables a plugin on the controller.

  `provider` is an entry from `get_provider_info/0`: it carries the provider's
  module name and its declared option fields. `form` carries values for those
  fields plus the subscription directives.
  """
  def enable_plugin(_plugin_id, nil, _form, _namespace, _operative_id) do
    {:error, "provider not found"}
  end

  def enable_plugin(plugin_id, provider, form, namespace, operative_id) do
    with {:ok, subscriptions} <- extract_subscriptions(form) do
      fields = [
        id: plugin_id,
        provider: to_module(provider.module),
        namespace: namespace,
        operative_id: operative_id,
        opts: provider_opts(form, provider),
        subscriptions: subscriptions
      ]

      # Built by the controller's own constructor so the struct stays valid if
      # it gains enforced fields, rather than hand-assembling the map here.
      with plugin when is_map(plugin) <- erpc_call(Flezha.Plugin, :new, [fields]) do
        erpc_call(Flezha.Service.PluginManager, :enable_plugin, [plugin_id, plugin])
      end
    end
  end

  @doc """
  Builds the `subscriptions` list from a plugin form.

  Accepts the repeatable `extensions` shape and the single `trigger` shape; the
  legacy trigger spellings `proactive` and `interval` both arm the interval
  tick on a five-second period, matching the controller's own mapping.
  """
  def extract_subscriptions(form) do
    names =
      case Map.get(form, "extensions") do
        list when is_list(list) -> list
        value when value not in [nil, ""] -> [value]
        _ -> List.wrap(blank_to_nil(Map.get(form, "trigger")))
      end

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case subscription(name, form) do
        {:ok, sub} -> {:cont, {:ok, acc ++ [sub]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp subscription(name, form) when name in ["proactive", "interval"] do
    {:ok, {:on_interval, Keyword.put_new(sub_opts(form), :interval_ms, 5_000)}}
  end

  defp subscription(name, form) do
    with {:ok, extension} <- extension_atom(name) do
      {:ok, {extension, sub_opts(form)}}
    end
  end

  # Matched against a fixed vocabulary rather than converted, so a crafted form
  # value cannot grow the atom table.
  defp extension_atom(name) when is_atom(name) do
    if name in @extensions, do: {:ok, name}, else: {:error, {:unknown_extension, name}}
  end

  defp extension_atom(name) when is_binary(name) do
    case Enum.find(@extensions, fn ext -> Atom.to_string(ext) == name end) do
      nil -> {:error, {:unknown_extension, name}}
      extension -> {:ok, extension}
    end
  end

  defp sub_opts(form) do
    Enum.flat_map(@sub_opts, fn opt ->
      case Map.get(form, @sub_opt_prefix <> Atom.to_string(opt)) do
        value when value in [nil, ""] -> []
        value -> [{opt, cast_sub_opt(value)}]
      end
    end)
  end

  # Form values arrive as strings; the host's validators expect integers for
  # `position`, `interval_ms`, and `timeout_ms`.
  defp cast_sub_opt(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp cast_sub_opt(value), do: value

  # Providers read their options under atom keys. Only fields the provider
  # itself declared are converted, so a crafted form field cannot grow the atom
  # table, and anything undeclared is dropped rather than handed to an
  # allow-list that would refuse the whole plugin.
  defp provider_opts(form, provider) do
    declared = Map.get(provider, :required_fields, []) ++ Map.get(provider, :optional_fields, [])

    Enum.reduce(declared, %{}, fn field, acc ->
      name = to_string(field)

      case Map.get(form, name) do
        value when value in [nil, ""] -> acc
        value -> Map.put(acc, safe_atom(name), value)
      end
    end)
  end

  # The name came from the controller's own provider info, so its atom already
  # exists there; falling back keeps a provider whose field is new to this node
  # working rather than crashing the enable.
  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> String.to_atom(name)
  end

  defp to_module(mod) when is_atom(mod), do: mod
  defp to_module("Elixir." <> _ = mod), do: safe_atom(mod)
  defp to_module(mod) when is_binary(mod), do: safe_atom("Elixir." <> mod)

  def enable_io_listener(namespace, operative_id, io_type, recv_pid) do
    erpc_call(Flezha.Service.PluginHelper, :enable_io_listener, [
      namespace,
      operative_id,
      io_type,
      recv_pid
    ])
  end

  def disable_plugin(plugin_id) do
    erpc_call(Flezha, :disable_plugin, [plugin_id])
  end

  def get_plugins() do
    erpc_call(Flezha.Service.PluginManager, :get_plugins, [])
  end

  @doc """
  One row per (extension, plugin) pair from an operative's overwatch state.

  The extension table's `subs` maps each extension name to the entries
  subscribed to it; provider and position live on the entry, so this is the
  only place that knows the table's shape.
  """
  def extension_entries(%{extensions: extensions}), do: extension_entries(extensions)

  def extension_entries(%{subs: subs}) when is_map(subs) do
    subs
    |> Enum.flat_map(fn {extension, entries} ->
      entries
      |> List.wrap()
      |> Enum.map(fn entry ->
        %{
          plugin_id: to_string(Map.get(entry, :plugin_id, "—")),
          extension: to_string(extension),
          provider: FlezhaUi.Format.module_name(Map.get(entry, :provider)),
          position: Map.get(entry, :position)
        }
      end)
    end)
    |> Enum.sort_by(&{&1.extension, &1.position || 0, &1.plugin_id})
  end

  def extension_entries(_), do: []

  def get_provider_info() do
    list_call(Flezha.Service.ConfigManager, :get_provider_info, [])
  end

  @doc """
  The enabled providers, as the plugin screens want them.

  `internal?` marks a provider an operator cannot configure by hand — one
  requiring a `recv_pid`, which only code holding a live pid can supply.

  Controller facts only; how they read on a screen is the view's business.
  """
  def providers do
    get_provider_info()
    |> ok_or([])
    |> Enum.map(fn info ->
      id = to_string(Map.get(info, :id, ""))
      required = Map.get(info, :required_fields, [])

      %{
        id: id,
        module: Map.get(info, :module, "unknown"),
        type: Map.get(info, :type, :unknown),
        required_fields: required,
        optional_fields: Map.get(info, :optional_fields, []),
        internal?: "recv_pid" in required
      }
    end)
  end

  # ---- Dead-letter queue ----
  #
  # The controller's CLI verbs for the DLQ print to stdout and exit on failure,
  # so they are presentation rather than API. These call the same store the CLI
  # calls, which keeps the two on identical semantics.

  @doc "Parked entries, nearest-to-expiry first. `nil` lists every class."
  def dlq_list(operative_class \\ nil) do
    list_call(Flezha.Dlq.Store, :list, [Flezha.Dlq.Store, blank_to_nil(operative_class)])
  end

  def dlq_get(entry_ref) do
    erpc_call(Flezha.Dlq.Store, :get, [Flezha.Dlq.Store, entry_ref])
  end

  def dlq_drop(entry_ref) do
    erpc_call(Flezha.Dlq.Store, :drop, [Flezha.Dlq.Store, entry_ref])
  end

  def dlq_mark_replaying(entry_ref) do
    erpc_call(Flezha.Dlq.Store, :mark_replaying, [Flezha.Dlq.Store, entry_ref])
  end

  def dlq_stats do
    list_call(Flezha.Dlq.Store, :stats, [Flezha.Dlq.Store])
  end

  @doc "How long the controller waits to see whether a replayed entry re-parks."
  def dlq_replay_grace_ms do
    case erpc_call(Application, :get_env, [:flezha, :dlq, []]) do
      opts when is_list(opts) -> Keyword.get(opts, :replay_grace_ms, 5_000)
      _ -> 5_000
    end
  end

  # ---- Schedules ----

  def schedule_list do
    list_call(Flezha.Schedule.Store, :list, [])
  end

  def schedule_add(fields) when is_map(fields) do
    erpc_call(Flezha.Schedule.Store, :add, [fields])
  end

  def schedule_remove(name) do
    erpc_call(Flezha.Schedule.Store, :remove, [name])
  end

  def schedule_statuses do
    erpc_call(Flezha.Schedule.Hub, :statuses, [])
  end

  def schedule_assert(entry) do
    erpc_call(Flezha.Schedule.Hub, :assert, [entry])
  end

  def schedule_retract(name) do
    erpc_call(Flezha.Schedule.Hub, :retract, [name])
  end

  @doc """
  When `cron` next fires in `timezone`.

  The hub's status reports the *last* fire, not the next one, so this is
  computed from the expression using the controller's own cron parser — the
  only thing that agrees with when the job will actually run.
  """
  def schedule_next_fire(cron, timezone) do
    with {:ok, parsed} <- erpc_call(Flezha.Schedule.Cron, :parse, [cron]) do
      erpc_call(Flezha.Schedule.Cron, :next_fire, [parsed, timezone, DateTime.utc_now()])
    end
  end

  # ---- Audit log ----
  #
  # `Flezha.Service.AuditLog` was written for this UI: its caller context takes
  # `:ui` as a first-class source, so it is used as-is.

  def audit_files do
    erpc_call(Flezha.Service.AuditLog, :list_files, [caller_context()])
  end

  def audit_read(params) when is_map(params) do
    erpc_call(Flezha.Service.AuditLog, :read, [params, caller_context()])
  end

  def audit_stats do
    erpc_call(Flezha.Service.AuditLog, :stats, [caller_context()])
  end

  # ---- Cluster and fleet ----

  def hub_nodes(namespace) do
    list_call(Flezha.Cluster.Directory, :hub_nodes, [namespace])
  end

  def active_runners(namespace) do
    list_call(Flezha.Runner.FleetManager, :active_runners, [namespace])
  end

  def runners_for_factory(namespace, factory_id) do
    list_call(Flezha.Runner.FleetManager, :runners_for_factory, [namespace, factory_id])
  end

  @doc "Erlang nodes the controller is clustered with, including itself."
  def controller_cluster_nodes do
    list_call(:erlang, :nodes, [[:this, :visible]])
  end

  @doc """
  The id out of a controller identifier, whatever shape it arrives in.

  `list_factories/1` answers maps carrying a description, the fleet functions
  answer bare ids or `{id, metadata}` tuples. Normalising here keeps every
  screen off the question.
  """
  def identifier_id(%{id: id}), do: to_string(id)
  def identifier_id(%{"id" => id}), do: to_string(id)
  def identifier_id({id, _metadata}), do: to_string(id)
  def identifier_id(id), do: to_string(id)
end
