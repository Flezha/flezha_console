defmodule FlezhaUi.Service.NodeManager do
  @moduledoc """
  The single seam between this UI and the flezha controller node.

  Every remote module name the UI depends on is declared here and nowhere else,
  so a controller API change is a one-file diff. Callers receive either the
  remote function's own reply or one of five normalised errors — never a raw
  `:erpc` exit:

    * `{:error, :node_not_connected}` — no controller node is reachable.
    * `{:error, {:api_missing, module, function, arity}}` — the controller does
      not export the call. This is the signal that UI and controller versions
      have diverged.
    * `{:error, :timeout}` — the controller did not answer in time.
    * `{:error, {:forbidden, reason}}` — authorization refused the call, or no
      principal is bound to it. A distinct shape because it has a distinct
      remedy: present a token, or be granted a role.
    * `{:error, {:remote_error, term}}` — anything else that went wrong on the
      remote side.
  """

  require Logger

  @default_timeout 15_000

  # Verified identities and the enforcement posture, so a screen that makes
  # several controller calls on one tick does not spend a round trip
  # re-establishing who it is before each of them.
  @cache :flezha_ui_authz_cache
  @token_ttl_ms 30_000
  @posture_ttl_ms 2_000

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

  # A service that raises its refusal rather than returning it still has to
  # reach a caller as a refusal — the shape carries the remedy.
  defp classify(
         :error,
         %ErlangError{original: {:exception, {:forbidden, reason}, _stack}},
         _m,
         _f,
         _args
       ),
       do: {:error, {:forbidden, reason}}

  defp classify(_kind, {:exception, {:forbidden, reason}, _stack}, _m, _f, _args),
    do: {:error, {:forbidden, reason}}

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

  # ---- Identity ----
  #
  # The rule is the controller's own (`Flezha.Service.CliManager.cli_context/1`):
  # identity comes only from a verified token. A principal typed into this UI is
  # never trusted, because a context this node assembles is a context the
  # controller's audit log would name — forging it would forge the trail.

  @doc """
  Creates the cache the identity reads share. Called once from the application
  supervisor's start, whose process outlives every request.
  """
  def init_cache do
    case :ets.whereis(@cache) do
      :undefined -> :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
      tid -> tid
    end
  end

  @doc """
  Verifies a flezha token against the controller's token store.

  Answers `{:ok, %{principal:, namespace:, role:, expires_at:}}` or the store's
  own `{:error, :malformed | :unknown | :token_revoked | :token_expired}`.
  A transport failure passes through as the seam's normalised error.

  Results are cached per token for a short period, never past the token's own
  `expires_at`. A transport failure is not cached — it is not an answer about
  the token.
  """
  def verify_token(nil), do: {:error, :no_token}
  def verify_token(""), do: {:error, :no_token}

  def verify_token(token) when is_binary(token) do
    case cache_get({:token, token_key(token)}) do
      {:ok, cached} ->
        cached

      :miss ->
        result = erpc_call(Flezha.AuthZ.TokenStore, :verify, [token])
        maybe_cache_verification(token, result)
        result
    end
  end

  def verify_token(_token), do: {:error, :malformed}

  @doc """
  Drops a token's cached verification, so the next call re-asks the controller.

  Used when a call is refused: a revocation then costs at most one refused call
  rather than a whole TTL of them.
  """
  def evict_token(token) when is_binary(token) do
    cache_delete({:token, token_key(token)})
    cache_delete({:authz, token_key(token)})
    :ok
  end

  def evict_token(_token), do: :ok

  @doc """
  The caller context every authorized controller service is called with.

  `source: :ui` plus the principal, namespace and role a verified token
  answered. An unresolvable token leaves the context unbound, which is the
  state the controller refuses and this UI explains.

  This is the only construction site for a caller context in the UI.
  """
  def caller_context(token \\ nil)

  def caller_context(token) when is_binary(token) and token != "" do
    case verify_token(token) do
      {:ok, %{principal: principal} = identity} when is_binary(principal) ->
        %{
          source: :ui,
          principal: principal,
          namespace: Map.get(identity, :namespace),
          role: Map.get(identity, :role)
        }

      _ ->
        %{source: :ui}
    end
  end

  def caller_context(_token), do: %{source: :ui}

  # An authorized controller service, called with the caller context appended.
  # Refusals evict the token's cached verification on the way out, which is what
  # makes a revoked token stop working within one call rather than one TTL.
  defp authorized_call(token, module, function, args) do
    refusal_aware(token, erpc_call(module, function, args ++ [caller_context(token)]))
  end

  # As `authorized_call/4`, normalised to `{:ok, list}` the way `list_call/3` is.
  defp authorized_list_call(token, module, function, args) do
    refusal_aware(token, list_call(module, function, args ++ [caller_context(token)]))
  end

  defp refusal_aware(token, {:error, {:forbidden, _reason}} = refusal) do
    evict_token(token)
    refusal
  end

  defp refusal_aware(_token, result), do: result

  @doc """
  The controller's enforcement posture: `:open`, `:bootstrap_pending` or
  `:enforced`.

  A controller predating authorization does not export it; that controller is
  open by definition, so the version-skew answer is normalised rather than
  shown as a broken panel.
  """
  def enforcement_posture do
    case erpc_call(Flezha.AuthZ, :enforcement_posture, []) do
      posture when posture in [:open, :bootstrap_pending, :enforced] -> posture
      {:error, {:api_missing, _m, _f, _a}} -> :open
      {:error, reason} -> {:error, reason}
      other -> {:error, {:remote_error, other}}
    end
  end

  @doc """
  Posture and bound identity together, as the layout renders them.

  Cached for the length of one refresh tick, because the layout is rendered far
  more often than the controller's answer changes.

    * `:posture` — `:open | :bootstrap_pending | :enforced`, or `nil` when the
      controller could not be asked.
    * `:principal`, `:namespace`, `:role` — the bound identity, or `nil`.
    * `:token?` — whether a token was presented at all, which separates "no
      credential" from "a credential the controller rejected".
    * `:reason` — why an presented token did not bind.
  """
  def authz_status(token \\ nil) do
    case cache_get({:authz, token_key(token)}) do
      {:ok, cached} ->
        cached

      :miss ->
        status = build_authz_status(token)
        cache_put({:authz, token_key(token)}, status, @posture_ttl_ms)
        status
    end
  end

  defp build_authz_status(token) do
    posture =
      case enforcement_posture() do
        posture when is_atom(posture) -> posture
        {:error, _reason} -> nil
      end

    base = %{
      posture: posture,
      principal: nil,
      namespace: nil,
      role: nil,
      expires_at: nil,
      token?: is_binary(token) and token != "",
      reason: nil
    }

    case verify_token(token) do
      {:ok, identity} ->
        %{
          base
          | principal: Map.get(identity, :principal),
            namespace: Map.get(identity, :namespace),
            role: Map.get(identity, :role),
            expires_at: Map.get(identity, :expires_at)
        }

      {:error, :no_token} ->
        base

      {:error, reason} ->
        %{base | reason: reason}
    end
  end

  @doc """
  What the bound token can reach: `:all` for a `_system` token, `{:namespace,
  ns}` for a namespace-scoped one, `:unbound` when nothing verified.

  The controller refuses a cross-namespace read with `namespace_mismatch`, so a
  switcher that offered every namespace would be offering errors.
  """
  def token_scope(token \\ nil) do
    case verify_token(token) do
      {:ok, %{namespace: namespace}} when namespace in ["_system", :_system] -> :all
      {:ok, %{namespace: namespace}} when is_binary(namespace) -> {:namespace, namespace}
      {:ok, _identity} -> :all
      {:error, _reason} -> :unbound
    end
  end

  @doc """
  `namespaces` narrowed to what `scope` can reach.

  An unbound caller is narrowed to nothing only when the controller is
  enforcing: against an open controller the UI can still read, and hiding every
  namespace there would be a refusal the controller never made.
  """
  def scope_namespaces(namespaces, :all), do: namespaces

  def scope_namespaces(namespaces, {:namespace, namespace}),
    do: Enum.filter(namespaces, &(to_string(&1) == to_string(namespace)))

  def scope_namespaces(namespaces, :unbound), do: namespaces

  @doc """
  The running namespaces `token` can reach, as `{names, error}`.

  The read every fleet-wide screen starts from: listing and scope narrowing are
  one rule, so two screens cannot disagree about what a namespace-scoped token
  is allowed to see.
  """
  def scoped_namespaces(token) do
    list_namespaces()
    |> ok_or_error([])
    |> then(fn {names, error} -> {scope_namespaces(names, token_scope(token)), error} end)
  end

  # ---- Identity cache ----

  # Keyed by a digest rather than the token, so a crash dump or a table listing
  # cannot hand out the credential.
  defp token_key(nil), do: :none
  defp token_key(""), do: :none
  defp token_key(token) when is_binary(token), do: :crypto.hash(:sha256, token)
  defp token_key(_token), do: :none

  defp maybe_cache_verification(token, {:ok, identity} = result) do
    cache_put({:token, token_key(token)}, result, verification_ttl(identity))
  end

  defp maybe_cache_verification(token, {:error, reason} = result)
       when reason in [:malformed, :unknown, :token_revoked, :token_expired] do
    cache_put({:token, token_key(token)}, result, @token_ttl_ms)
  end

  # A transport failure is not an answer about the token, so it is not cached.
  defp maybe_cache_verification(_token, _result), do: :ok

  defp verification_ttl(%{expires_at: expires_at}) when is_integer(expires_at) do
    remaining_ms = expires_at * 1_000 - System.system_time(:millisecond)

    min(@token_ttl_ms, max(remaining_ms, 0))
  end

  defp verification_ttl(_identity), do: @token_ttl_ms

  defp cache_get(key) do
    case :ets.lookup(@cache, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          cache_delete(key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    # No cache table (an escript, a bare unit test): every read goes remote,
    # which is correct, only slower.
    ArgumentError -> :miss
  end

  defp cache_put(_key, _value, ttl_ms) when ttl_ms <= 0, do: :ok

  defp cache_put(key, value, ttl_ms) do
    :ets.insert(@cache, {key, value, System.monotonic_time(:millisecond) + ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cache_delete(key) do
    :ets.delete(@cache, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # A call that answers a collection, normalised to `{:ok, list}`. The
  # controller is inconsistent about this — some functions answer a bare list,
  # others `{:ok, list}` — so each named wrapper below is spared its own
  # unwrapper.
  defp list_call(module, function, args) do
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

  @doc """
  The value out of a call result and the reason it failed, as `{value, error}`.

  `ok_or/2` for a section that only needs the value; this for one that also has
  to say why it is empty, so a screen states a refusal instead of writing the
  same two-branch `case` for every panel it loads.
  """
  def ok_or_error({:ok, value}, _default), do: {value, nil}
  def ok_or_error({:error, reason}, default), do: {default, reason}

  # ---- Namespace / Operative API ----

  def list_namespaces() do
    list_call(Flezha, :list_namespaces, [])
  end

  def list_operatives(namespace) do
    list_call(Flezha, :list_operatives, [namespace])
  end

  @doc """
  Every operative in a namespace, from one registry dump.

  Each row carries `id`, the `health` the Convergence Loop classified, the
  bound `runner`, the declared `factory`, the `partition` identity (or `nil`),
  and the live `node` (or `nil` for an unplaced row). One call answers a whole
  namespace, which is what makes a listing's cost flat in the size of the
  fleet — `list_operatives/1` answers ids alone, and health would then be an
  overwatch round-trip per row.

  A row the loop has not observed yet reports `:unknown`.
  """
  def operative_rows(namespace) do
    list_call(Flezha.Service.HubManager, :operative_rows, [namespace])
  end

  @doc """
  Declared plugins per operative for a whole namespace, as
  `[{operative_id, [plugin]}]`, from the same dump `operative_rows/1` walks.

  Operatives with no declared plugins are absent from the list, so a caller
  wanting a per-row count should default a missing id to zero.
  """
  def operative_plugins(namespace) do
    list_call(Flezha.Service.HubManager, :operative_plugins, [namespace])
  end

  # `rows` with each partition group's members collapsed into one group row.
  #
  # The controller's own function: it is documented there as the pure seam
  # between `operative_rows/1` and the renderers, and a group is exactly as
  # healthy as its sickest member. Re-deriving the rollup here would be a second
  # implementation of a rule the controller owns.
  #
  # A group row carries `partitions` ("3/4") and `members`; an ungrouped
  # operative passes through untouched.
  defp group_partition_rows(rows) when is_list(rows) do
    list_call(Flezha.Service.CliManager, :group_partition_rows, [rows])
  end

  @doc """
  A namespace's operative rows with their health resolved.

  The read every listing starts from, in one place: `operative_rows/1` answers
  the registry, and a row the Convergence Loop has not observed is `:unknown`
  rather than absent. A failed read answers `[]` — a screen states the failure
  from its own `load_error`, it does not need this to raise.
  """
  def namespace_rows(namespace) do
    namespace |> operative_rows() |> ok_or([]) |> decorate_health()
  end

  @doc """
  Rows with their health resolved, for a caller that read `operative_rows/1`
  itself — a screen that needs the read's failure reason rather than an empty
  list still gets the one decoding rule.
  """
  def decorate_health(rows) when is_list(rows) do
    Enum.map(rows, &Map.put(&1, :health, row_health(&1)))
  end

  @doc """
  A namespace's partition groups, each carrying its coverage verdict.

  The single derivation: the controller collapses the members, the controller
  checks the coverage, and this attaches one to the other. `:coverage` is
  `:complete`, a `%{gaps:, overlaps:}` fault, or `:unavailable` when the
  controller could not be asked — which must never read as covered.

  Takes rows the caller already has, so a screen showing both a group panel and
  a fleet summary pays for one derivation rather than two.
  """
  def partition_groups(rows) when is_list(rows) do
    rows
    |> group_partition_rows()
    |> ok_or([])
    |> Enum.filter(&Map.has_key?(&1, :members))
    |> Enum.map(&Map.put(&1, :coverage, coverage_verdict(&1)))
  end

  @doc "The ids of the groups whose coverage is faulted."
  def faulted_group_ids(groups) when is_list(groups) do
    groups |> Enum.filter(&is_map(&1.coverage)) |> Enum.map(& &1.id)
  end

  # `{:error, %{gaps: _}}` is the check's own verdict; any other error is the
  # seam saying it could not ask.
  defp coverage_verdict(group) do
    case partition_coverage(group.members) do
      :ok -> :complete
      {:error, %{gaps: gaps, overlaps: overlaps}} -> %{gaps: gaps, overlaps: overlaps}
      _unavailable -> :unavailable
    end
  end

  # Whether a group's members own every key group exactly once: `:ok`, or
  # `{:error, %{gaps: [{from, to}], overlaps: [{key_group, owners}]}}`. The
  # controller's own check, because a key range nobody owns is silent data loss
  # and the UI has no business deciding what counts as covered.
  #
  # `group_partition_rows/1` does not carry coverage — the controller computes
  # it in a separate pass — so it is asked for per group. Groups are few; this
  # does not grow with the number of operatives.
  defp partition_coverage(members) when is_list(members) do
    erpc_call(Flezha.Partition, :coverage, [Enum.map(members, &{&1.id, &1.partition.range})])
  end

  @doc """
  Every operative's kind in a namespace, as `%{operative_id => :stream | :workflow}`.

  Kind is fixed at start and recorded durably in the registry entry's cspec, so
  a whole namespace's kinds cost one read — `operative_rows/1` walks the same
  dump but projects only the fields the CLI's listing needs.

  Absent from the map means the entry carried no builder; the controller reads
  that as `:stream` (`CliManager.operative_kind/1`), and so does this.
  """
  def operative_kinds(namespace) do
    case erpc_call(Flezha.Service.HubManager, :get_registry, [namespace]) do
      {:ok, dump} when is_list(dump) -> {:ok, Map.new(dump, &kind_entry/1)}
      {:ok, dump} when is_map(dump) -> {:ok, Map.new(dump, &kind_entry/1)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:remote_error, other}}
    end
  end

  defp kind_entry({operative_id, entry}) do
    {to_string(operative_id), cspec_kind(entry)}
  end

  # The registry entry's cspec start-args, in the shapes the controller's own
  # `cspec_operative/1` recognises. Decoded here for the same reason
  # `decode_overwatch/2` exists: the controller answers a shape this node
  # cannot pattern-match, and exactly one place should know it.
  defp cspec_kind({cspec, _node_pids, _metadata}), do: cspec_kind(cspec)
  defp cspec_kind({cspec, _node_pids}), do: cspec_kind(cspec)

  defp cspec_kind(%{start: {_module, _function, [arg]}}) do
    case arg do
      {_namespace, %{} = operative} -> Map.get(operative, :kind) || :stream
      {_namespace, _runner, %{} = operative} -> Map.get(operative, :kind) || :stream
      _other -> :stream
    end
  end

  defp cspec_kind(_entry), do: :stream

  # Health as the Convergence Loop classifies it, healthiest first.
  #
  # `:suspended` is a health value, not a separate fact: the loop probes each
  # instance's overwatch itself and ranks suspension in the same ladder
  # ("evicted at a committed iteration boundary, not broken"). That is what
  # makes suspension readable namespace-flat — it rides `operative_rows/1`
  # rather than costing a call per instance.
  #
  # `:unknown` is a row the loop has not observed yet — last, and never rounded
  # up to healthy.
  @health_kinds [:healthy, :suspended, :degraded, :unbound, :failed, :unknown]

  @doc "The health values an operative row can carry, healthiest first."
  def health_kinds, do: @health_kinds

  # The operative kinds this UI knows how to offer. Kept here, beside
  # `@health_kinds`, for the same reason: a screen that hardcoded its own copy
  # would drift from the one the start form starts operatives with.
  @kind_candidates [:stream, :workflow]

  @doc """
  The kinds the controller recognises, as `[%{kind:, capabilities: [atom]}]`.

  A candidate the controller does not know is dropped, so this UI cannot offer
  a kind whose start would be refused. A controller that cannot answer at all
  yields every candidate with no capabilities — the form is still usable, it
  just cannot say what choosing a kind costs.

  `Flezha.Operative.Kind.capabilities/1` answers a sparse map of the flags a
  kind declares true; a sorted list of those flags is what a form renders.
  """
  def known_kinds do
    Enum.flat_map(@kind_candidates, fn kind ->
      case erpc_call(Flezha.Operative.Kind, :known?, [kind]) do
        true -> [%{kind: kind, capabilities: kind_capabilities(kind)}]
        false -> []
        _unanswerable -> [%{kind: kind, capabilities: []}]
      end
    end)
  end

  defp kind_capabilities(kind) do
    case erpc_call(Flezha.Operative.Kind, :capabilities, [kind]) do
      %{} = declared ->
        declared |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      _unanswerable ->
        []
    end
  end

  @doc """
  A row's health, reading an absent or `nil` value as `:unknown`.

  Never `:healthy` by default: an aggregate that rounded an unobserved row up
  would hide exactly the case the column exists for.
  """
  def row_health(%{health: health}) when is_atom(health) and not is_nil(health), do: health
  def row_health(_row), do: :unknown

  @doc """
  `rows` counted by health, as `{health, count}` in `health_kinds/0` order,
  empty buckets omitted.

  A health this UI does not know is kept under its own name rather than folded
  into `:unknown` — the controller named it for a reason.
  """
  def health_counts(rows) when is_list(rows) do
    counted = Enum.frequencies_by(rows, &row_health/1)

    known =
      for kind <- @health_kinds, count = Map.get(counted, kind, 0), count > 0, do: {kind, count}

    known ++ Enum.sort(Map.drop(counted, @health_kinds))
  end

  @doc "The rows with no live node — placed nowhere, so serving nothing."
  def unplaced_rows(rows) when is_list(rows), do: Enum.filter(rows, &is_nil(&1[:node]))

  @doc "The rows that are on a live node. The exact complement of `unplaced_rows/1`."
  def placed_rows(rows) when is_list(rows), do: Enum.reject(rows, &is_nil(&1[:node]))

  @doc """
  Plugin counts per operative id, from `operative_plugins/1`'s pairs.

  Keyed by string id, because a row's id and a plugin pair's id are the same
  value in two shapes.
  """
  def plugin_counts(pairs) when is_list(pairs) do
    Map.new(pairs, fn {id, plugins} -> {to_string(id), length(List.wrap(plugins))} end)
  end

  @doc """
  A catalog inverted to `%{runner_id => [factory_id]}`, each list sorted.

  The cluster screen reads a fleet the other way round — "what does this runner
  serve" — from the same catalog every factory picker is built from, so the two
  cannot disagree about which runner serves what.
  """
  def factories_by_runner(catalog) when is_list(catalog) do
    catalog
    |> Enum.reduce(%{}, fn %{id: factory, runners: runners}, acc ->
      Enum.reduce(runners, acc, &Map.update(&2, &1, [factory], fn known -> [factory | known] end))
    end)
    |> Map.new(fn {runner, factories} -> {runner, Enum.sort(factories)} end)
  end

  def list_runners(namespace) do
    list_call(Flezha, :list_runners, [namespace])
  end

  def list_factories(namespace) do
    list_call(Flezha, :list_factories, [namespace])
  end

  @doc """
  A namespace's registered factories with the runners serving each, as
  `[%{id:, description:, runners: [runner_id], servable?: boolean}]` sorted by
  id.

  Every screen that names a factory reads it from here: the picker needs to
  mark a factory no runner serves, and the cluster screen needs the same pairing
  the other way round. Costs the listing plus one lookup per factory — the price
  the fleet view already paid, now paid once for every caller.

  Read when a form that needs it opens, never on a refresh tick: a listing that
  re-read it per namespace per tick would turn a flat screen into a call storm
  for a form that is usually closed. A runner that disconnects while the form is
  open therefore leaves `servable?` stale — the controller's refusal is still
  the authority, so that costs a failed attempt, not a wrong outcome.
  """
  def factory_catalog(namespace) do
    with {:ok, factories} <- list_factories(namespace) do
      {:ok, factories |> Enum.map(&factory_entry(namespace, &1)) |> Enum.sort_by(& &1.id)}
    end
  end

  defp factory_entry(namespace, factory) do
    id = identifier_id(factory)

    runners =
      namespace
      |> runners_for_factory(id)
      |> ok_or([])
      |> Enum.map(&identifier_id/1)
      |> Enum.sort()

    %{
      id: id,
      description: factory_description(factory),
      runners: runners,
      servable?: runners != []
    }
  end

  defp factory_description(%{description: description}), do: description
  defp factory_description(%{"description" => description}), do: description
  defp factory_description(_factory), do: nil

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

  @doc """
  A form's typed init values as the spec map the controller takes, or the
  message to put on the form.

  Blank means no init values rather than invalid ones — every form offering
  them treats an untouched field as `%{}`. Both forms that carry init values,
  the operative launcher and the schedule form, decode them here so a document
  one accepts is not one the other refuses.
  """
  def parse_init_values(raw) do
    case String.trim(raw || "") do
      "" ->
        {:ok, %{}}

      json ->
        with {:error, _reason} <- Jason.decode(json),
             do: {:error, "Init Values must be valid JSON."}
    end
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

  @doc """
  The facts a screen wants out of an operative's overwatch state.

  The controller answers a struct this node cannot pattern-match, and each
  field needs its own rule to read: `kind` falls back to the builder the
  operative was started from, the dead-letter class defaults to the id, uptime
  is a wall-clock difference. Decoding it here is the bargain `extension_entries/1`
  already makes — one place knows the shape, instead of each screen holding
  half of it.

  `overwatch_facts/0` is the same shape with nothing in it, for a screen whose
  read failed.
  """
  def overwatch_facts(namespace, operative_id) do
    case get_overwatch_state(namespace, operative_id) do
      {:ok, state} when is_map(state) -> {:ok, decode_overwatch(state, operative_id)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:remote_error, other}}
    end
  end

  def overwatch_facts, do: decode_overwatch(%{}, nil)

  defp decode_overwatch(state, operative_id) do
    started_at = Map.get(state, :started_at)

    %{
      factory_id: Map.get(state, :factory_id),
      runner_id: overwatch_runner(Map.get(state, :runner_id)),
      kind: Map.get(state, :kind) || builder_kind(Map.get(state, :builder)),
      suspended: Map.get(state, :suspended, false),
      effectively_once: Map.get(state, :effectively_once, false),
      # The workflow profile. Defaulted rather than required, so an older
      # controller whose overwatch omits a field decodes instead of failing.
      durable_workflow: Map.get(state, :durable_workflow, false),
      correction_window_ms: Map.get(state, :correction_window_ms),
      arrived_via_hotswap?: Map.get(state, :arrived_via_hotswap?, false),
      init_error: Map.get(state, :init_error),
      default_input_type: Map.get(state, :default_input_type),
      started_at: started_at,
      uptime_ms: uptime(started_at),
      operative_class: operative_class(state, operative_id),
      bindings: extension_entries(state)
    }
  end

  defp builder_kind(%{kind: kind}), do: kind
  defp builder_kind(_builder), do: nil

  defp overwatch_runner(nil), do: nil
  defp overwatch_runner(id), do: identifier_id(id)

  # An operative's dead-letter class is its id unless the builder overrode it —
  # the controller's own rule, so a DLQ join agrees with what parked there.
  defp operative_class(_state, nil), do: nil

  defp operative_class(%{builder: %{opts: opts}}, operative_id) when is_list(opts) do
    to_string(Keyword.get(opts, :operative_class, operative_id))
  end

  defp operative_class(_state, operative_id), do: to_string(operative_id)

  # `started_at` is wall-clock ms, so it stays comparable read from another node.
  defp uptime(started_at) when is_integer(started_at) do
    System.system_time(:millisecond) - started_at
  end

  defp uptime(_started_at), do: nil

  # ---- Workflow instances ----

  @doc """
  Workflow instances that have finished but are still retained, as
  `[{operative_id, completion_record}]`.

  The controller's own rule, copied from `CliManager.finished_operatives/2` so
  the UI and `flz operative list` agree on what "recently finished" means: an
  operative class that is no longer live, whose completion record names this
  namespace, and whose `finished_at` is inside the class's own
  `workflow_completed_retention_hours`.

  `live_ids` is passed in rather than re-read, so a caller that already holds
  `operative_rows/1` does not pay for them twice.

  Costs one call plus one per persisted class that is not live. There is no
  bulk completion read on the controller, which is why this is not on a refresh
  tick.
  """
  def finished_instances(namespace, live_ids) when is_list(live_ids) do
    live = MapSet.new(live_ids, &to_string/1)

    with {:ok, classes} <- list_call(Flezha.State.Registry, :operative_classes, []) do
      now = System.system_time(:second)

      {:ok,
       classes
       |> Enum.reject(&MapSet.member?(live, to_string(&1)))
       |> Enum.flat_map(&retained_completion(&1, namespace, now))}
    end
  end

  # `Completion.read/1` answers a bare `:error` for a class with no record.
  defp retained_completion(operative_id, namespace, now) do
    with {:ok, %{namespace: ns, finished_at: finished_at} = record}
         when ns == namespace and is_integer(finished_at) <-
           erpc_call(Flezha.State.Completion, :read, [operative_id]),
         hours when is_number(hours) <-
           erpc_call(Flezha.State.PersistenceResolver, :workflow_completed_retention_hours, [
             operative_id
           ]),
         true <- finished_at + hours * 3600 >= now do
      [{to_string(operative_id), record}]
    else
      _outside_window_or_unreadable -> []
    end
  end

  @doc "The retention window, in hours, that applies to an operative class."
  def workflow_retention_hours(operative_class) do
    erpc_call(Flezha.State.PersistenceResolver, :workflow_completed_retention_hours, [
      operative_class
    ])
  end

  @doc """
  A durable instance's journal entries, newest first.

  Answers `{:ok, []}` for an instance with no journal, which is how a
  non-durable operative reads — the panel is absent rather than empty.
  """
  def proc_journal(instance_id) do
    with {:ok, entries} <- list_call(Flezha.State.ProcJournal, :read, [instance_id]) do
      {:ok, Enum.sort_by(entries, &Map.get(&1, :seq, 0), :desc)}
    end
  end

  @doc "The iterations the journal reports as committed — the only rewind targets."
  def journal_committed_iterations(instance_id) do
    list_call(Flezha.State.ProcJournal, :committed_iterations, [instance_id])
  end

  @doc "How far the instance has consumed its inbox."
  def journal_consumed_offset(instance_id) do
    erpc_call(Flezha.State.ProcJournal, :consumed_offset, [instance_id])
  end

  @doc "Inbox entries the instance has not consumed yet."
  def inbox_undelivered(instance_id) do
    list_call(Flezha.State.ProcInbox, :undelivered, [instance_id])
  end

  @doc "The highest offset written to the instance's inbox."
  def inbox_last_offset(instance_id) do
    erpc_call(Flezha.State.ProcInbox, :last_offset, [instance_id])
  end

  @doc "Rescales a partition group to `target` members."
  def rescale_group(namespace, group_id, target) when is_integer(target) do
    erpc_call(Flezha.Operative.PartitionGroup, :rescale, [namespace, group_id, target, []])
  end

  @doc """
  Rewinds a durable instance to a committed iteration.

  The overwatch pid is resolved first because the controller's rewind is a call
  on that process; both hops run on the controller, so the pid never has to
  mean anything on this node.
  """
  def rewind_instance(namespace, operative_id, to_iter) when is_integer(to_iter) do
    case erpc_call(Flezha.Service.OperativeManager, :get_operative_pid, [namespace, operative_id]) do
      pid when is_pid(pid) ->
        erpc_call(Flezha.Operative.Lifecycle, :rewind, [pid, to_iter])

      {:ok, pid} when is_pid(pid) ->
        erpc_call(Flezha.Operative.Lifecycle, :rewind, [pid, to_iter])

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:remote_error, other}}
    end
  end

  # ---- Namespaces as declared objects ----
  #
  # `Flezha.list_namespaces/0` answers *running hubs*. A namespace is also a
  # declared object with quotas and role bindings, and one can exist without
  # the other — a declared namespace with no hub, or a hub for a namespace
  # nobody declared. Both halves are read here so a screen can say which it is.

  @doc "Declared namespaces, each `%{name:, quotas:, created_at:, created_by_principal:}`."
  def declared_namespaces do
    list_call(Flezha.AuthZ.NamespaceStore, :list, [])
  end

  @doc """
  Every namespace name a caller can see: declared union running, narrowed to
  the token's scope and sorted.

  The two populations genuinely differ — a namespace can be declared with no
  hub, and a hub can run for a namespace nobody declared — so a screen that
  counted one while listing the other would disagree with itself. Derived once,
  here, for both.
  """
  def known_namespace_names(declared, running, scope) do
    (Enum.map(declared, &to_string(&1.name)) ++ Enum.map(running, &to_string/1))
    |> Enum.uniq()
    |> Enum.sort()
    |> scope_namespaces(scope)
  end

  @doc "One declared namespace, or `{:error, :not_found}` — the store answers a bare `:error`."
  def declared_namespace(name) do
    case erpc_call(Flezha.AuthZ.NamespaceStore, :get, [name]) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:remote_error, other}}
    end
  end

  @doc "Declares a namespace. `quotas` is a map of overrides over the controller's defaults."
  def create_namespace(name, quotas \\ %{}, token \\ nil) do
    erpc_call(Flezha.AuthZ.NamespaceStore, :create, [
      name,
      [quotas: quotas, created_by_principal: principal_of(token)]
    ])
  end

  def delete_namespace(name) do
    erpc_call(Flezha.AuthZ.NamespaceStore, :delete, [name])
  end

  @doc "Replaces a namespace's quota overrides. Only the kinds given are sent."
  def set_namespace_quotas(name, quotas) when is_map(quotas) do
    erpc_call(Flezha.AuthZ.NamespaceStore, :set_quotas, [name, quotas])
  end

  # The counter kinds the controller tracks per namespace.
  defp quota_kinds do
    list_call(Flezha.AuthZ.QuotaCounters, :kinds, [])
  end

  # One namespace counter's current value. The store answers `0` for an absent
  # counter.
  defp quota_counter(namespace, kind) do
    erpc_call(Flezha.AuthZ.QuotaCounters, :get, [namespace, kind])
  end

  # Which quota key limits which counter. The controller's own
  # `Quotas.counter_for/1` is private, so the inverse is carried here — for the
  # five kinds `QuotaCounters.kinds/0` reports. `:max_message_rate_per_second`
  # maps to a `:messages` counter that `kinds/0` does not report, so there is
  # nothing to meter it against and it is deliberately absent.
  @quota_limit_keys %{
    operatives: :max_operatives,
    entities: :max_entities_per_operative,
    mailbox_bytes: :max_mailbox_bytes_total,
    runners: :max_runners,
    disk_bytes: :max_state_bytes
  }

  # The quota key that limits a counter kind, or `nil` when none does.
  defp quota_limit_key(kind), do: Map.get(@quota_limit_keys, kind)

  @doc """
  A namespace's counters paired with the limits that apply to them.

  `quotas` is the declared namespace's own quota map, or `nil` for a namespace
  with no declaration — every row then reports its value with no limit, which
  is what "no meter drawn against an absent limit" means.

  Costs one call per counter kind: the controller exposes no bulk counter read.
  """
  def quota_usage(namespace, quotas) do
    kinds = ok_or(quota_kinds(), Map.keys(@quota_limit_keys))

    Enum.map(kinds, fn kind ->
      limit = quotas && Map.get(quotas, quota_limit_key(kind))
      value = counter_value(quota_counter(namespace, kind))

      %{
        kind: kind,
        limit_key: quota_limit_key(kind),
        value: value,
        limit: limit,
        breached?: is_integer(limit) and is_integer(value) and value >= limit
      }
    end)
  end

  defp counter_value(value) when is_integer(value), do: value
  defp counter_value(_value), do: nil

  @doc "Role bindings for a namespace, each `%{principal:, namespace:, role:, bound_at:, bound_by:}`."
  def role_bindings(namespace) do
    list_call(Flezha.AuthZ.RoleStore, :list_for_namespace, [namespace])
  end

  # The principal a write is attributed to, taken from the same verified token
  # every other call is made with — never from a form.
  defp principal_of(token) do
    case caller_context(token) do
      %{principal: principal} -> principal
      _unbound -> nil
    end
  end

  # ---- Plugin API ----

  # A plugin form names its two kinds of value with a prefix each, so a provider
  # that declares a field called `position` stays distinguishable from the
  # subscription option of that name. Both prefixes are stripped here, which is
  # what lets a screen hand the form over untouched instead of translating it.
  @sub_opt_prefix "sub_"
  @provider_opt_prefix "field_"

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
  A plugin form built from plain provider settings.

  `enable_plugin/5` reads the provider's fields under this module's own form
  prefix, so a caller holding settings rather than a submitted form builds the
  form here instead of spelling the prefix itself.
  """
  def provider_form(settings, extensions) when is_map(settings) do
    settings
    |> Map.new(fn {name, value} -> {@provider_opt_prefix <> to_string(name), value} end)
    |> Map.put("extensions", extensions)
  end

  @doc """
  Enables a plugin on the controller.

  `provider` is an entry from `get_provider_info/0`: it carries the provider's
  module name and its declared option fields. `form` is the attach form as
  submitted — `field_<name>` for a provider option, `sub_<name>` for a
  subscription option, plus `trigger` or `extensions`.
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

      case Map.get(form, @provider_opt_prefix <> name) do
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

  @doc """
  A provider's own documentation for the options it takes.

  The controller offers one help string per provider rather than per-field
  descriptions, so this is what "explain the options" can honestly mean. A
  provider that exports none answers `nil` and the form renders bare fields.
  """
  def provider_help(%{module: module}) do
    case erpc_call(to_module(module), :help, []) do
      help when is_binary(help) -> help
      _unavailable -> nil
    end
  end

  def provider_help(_provider), do: nil

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

  @doc """
  The `{operative_class, procedure_id}` pairs that have parked entries.

  Unlike the other store functions this one takes no store argument — it reads
  the queue's directory layout, which is how the tier groups what it ships.
  """
  def dlq_procedures(operative_class \\ nil) do
    list_call(Flezha.Dlq.Store, :procedures, [blank_to_nil(operative_class)])
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

  def audit_files(token \\ nil) do
    authorized_call(token, Flezha.Service.AuditLog, :list_files, [])
  end

  def audit_read(params, token \\ nil) when is_map(params) do
    authorized_call(token, Flezha.Service.AuditLog, :read, [params])
  end

  def audit_stats(token \\ nil) do
    authorized_call(token, Flezha.Service.AuditLog, :stats, [])
  end

  # ---- Data plane and observability ----

  @doc """
  The controller's always-on data-plane counters.

  Answers `%{channels: [...], operatives: [...]}` exactly as the controller
  produced it: one entry per channel (keyed by runner id and stream name) and
  one per operative instance, every value a monotonic count. Rates are the
  caller's business — this is a point reading.
  """
  def liveness_snapshot do
    erpc_call(Flezha.Transport.LivenessCounters, :snapshot_all, [])
  end

  @doc """
  Recent signals from the controller's observability ring buffer.

  `params` is the service's own query map — `%{source: atom, limit: n,
  from_ts: us}`. The remote's `{:error, reason}` is its own answer and passes
  through untouched, so a caller can tell "observability is switched off" from
  a transport failure and render the affected region as absent rather than
  failed.
  """
  def observability_query(params, token \\ nil) when is_map(params) do
    authorized_call(token, Flezha.Service.Observability, :query, [params])
  end

  @doc """
  The controller's monotonic clock, in microseconds.

  Observability signals are stamped with the controller's monotonic time, which
  shares no epoch with this node's. Reading the controller's own clock is the
  only way to say how old a signal is; a local clock would answer confidently
  and wrongly.
  """
  def controller_monotonic_us do
    erpc_call(:erlang, :monotonic_time, [:microsecond])
  end

  # ---- Controller health ----

  @doc "The durability backend the controller is configured with, or `:unset`."
  def durability_backend, do: erpc_call(Flezha.State.DurabilityTier, :configured_backend, [])

  @doc "`:remote_tier` when a backend is shipping, `:local_only` when durable state has one copy."
  def durability_posture, do: erpc_call(Flezha.State.DurabilityTier, :posture, [])

  @doc "References whose time since the last successful ship is past the RPO target."
  def durability_breaches, do: list_call(Flezha.State.DurabilityTier, :breaches, [])

  @doc "Per-reference shipping state, including which writer superseded this node."
  def durability_status, do: list_call(Flezha.State.DurabilityTier, :status, [])

  @doc "Whether a shutdown is under way, its phase, and the graceful-shutdown configuration."
  def shutdown_status, do: erpc_call(Flezha.Shutdown.Coordinator, :status, [])

  @doc """
  Per-namespace boot state: the hub's recovery state and its registry row count.

  Composed from the same reads `flz boot status` makes — that verb prints, so
  the underlying functions are called directly.
  """
  def boot_status do
    with {:ok, namespaces} <- list_call(Flezha.Service.HubManager, :get_running_namespaces, []) do
      {:ok,
       Enum.map(namespaces, fn namespace ->
         %{namespace: to_string(namespace), recovery_state: hub_recovery_state(namespace)}
       end)}
    end
  end

  # A namespace hub's recovery state, or `:unavailable` when the controller
  # cannot answer — a hub still replaying is not the same as one serving, and a
  # column that guessed would erase the difference.
  defp hub_recovery_state(namespace) do
    with hub_id when is_atom(hub_id) <-
           erpc_call(Flezha.Service.Identificator, :hub, [namespace]),
         state when is_atom(state) <-
           unwrap(erpc_call(Flezha.Service.HubManager, :recovery_state, [hub_id])) do
      state
    else
      _unavailable -> :unavailable
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(value), do: value

  @doc """
  The controller's memory hot spots: top processes, ETS tables, DETS files and
  the allocator breakdown, with the time it was captured.

  Expensive — a process scan plus `:recon_alloc` — so it is only ever taken
  when an operator asks, never on a refresh tick.
  """
  def memory_snapshot, do: erpc_call(Flezha.Service.CliManager, :build_mem_top_snapshot, [])

  # ---- Observability control ----

  @doc """
  Whether a source is emitting.

  The controller carries `:status` (`:active` | `:disabled`) on the entry — not
  an `:enabled` boolean — so the reading lives here rather than in a template
  that would have to guess.
  """
  def source_enabled?(source), do: Map.get(source, :status) == :active

  @doc """
  Whether a sink is running.

  A sink entry carries no enabled flag at all; what it has is a `:pid`, set
  while its process is up. That is the honest analogue, and calling it
  "enabled" would imply a switch the controller does not offer.
  """
  def sink_running?(sink), do: is_pid(Map.get(sink, :pid))

  @doc "Every observability source with its enabled state."
  def observability_sources(token \\ nil) do
    authorized_list_call(token, Flezha.Service.Observability, :list_sources, [])
  end

  @doc "Every observability sink with its enabled state."
  def observability_sinks(token \\ nil) do
    authorized_list_call(token, Flezha.Service.Observability, :list_sinks, [])
  end

  @doc """
  Enables an observability source.

  `source` must be an atom the controller already named — it comes back from
  `observability_sources/1` and is passed through untouched, so a value typed
  into a form can never grow this node's atom table.
  """
  def enable_source(source, token \\ nil) when is_atom(source) do
    authorized_call(token, Flezha.Service.Observability, :enable_source, [source])
  end

  def disable_source(source, token \\ nil) when is_atom(source) do
    authorized_call(token, Flezha.Service.Observability, :disable_source, [source])
  end

  # ---- Durable state ----

  @doc """
  Every persisted entity's durability counters, as `[{entity_id, counters}]`
  where `entity_id` is `{operative_class, procedure_id, entity_key}`.

  One call for the whole controller; a screen narrows it to the class it is
  showing rather than asking per entity.
  """
  def state_metrics, do: list_call(Flezha.State.Metrics, :snapshot_all, [])

  @doc """
  An entity's state at a point in the past.

  `target` is `{:seq, n}` or `{:timestamp, unix_ms}`. A target before the
  retained history answers the controller's own error, which arrives as the
  exception struct it raised — read as a map, since its module is not loadable
  here.
  """
  def time_travel(entity_id, target) do
    erpc_call(Flezha.State.TimeTravel, :query, [entity_id, target])
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

  @doc """
  The principal the controller mints for a runner connecting to `namespace`.

  Namespace-derived and identical for every runner in it, which is exactly what
  the audit log will name. Answers `nil` on a controller that does not carry
  runner principals, so the column can be absent rather than guessed.
  """
  def runner_principal(namespace) do
    case erpc_call(Flezha.Runner.FleetManager, :runner_caller_context, [namespace]) do
      %{principal: principal} when is_binary(principal) -> principal
      _unavailable -> nil
    end
  end

  @doc """
  Each node's hub recovery state for `namespace`, keyed by node.

  The controller's own fan-out — the same one `flz cluster status` uses — so a
  hub still replaying is distinguishable from one that is serving, and the two
  views cannot disagree.
  """
  def cluster_recovery(namespace, nodes) when is_list(nodes) do
    case erpc_call(Flezha.Service.CliManager, :cluster_status_recovery, [namespace, nodes]) do
      %{} = per_node -> per_node
      _unavailable -> %{}
    end
  end

  @doc "Plugins installed on the controller host, each with its id, version and status."
  def installed_plugins do
    list_call(Flezha.Plugin.Installer, :list, [])
  end

  @doc "Erlang nodes the controller is clustered with, including itself."
  def controller_cluster_nodes do
    list_call(:erlang, :nodes, [[:this, :visible]])
  end

  @doc """
  The id out of a controller identifier, whatever shape it arrives in.

  `list_factories/1` answers maps carrying a description, the fleet functions
  answer bare ids or `{id, metadata}` tuples, and anything named through the
  controller's process registry — a stream channel, say — arrives as the
  `:via` tuple it was registered under. Normalising here keeps every screen off
  the question.
  """
  def identifier_id(%{id: id}), do: to_string(id)
  def identifier_id(%{"id" => id}), do: to_string(id)
  def identifier_id({:via, _registry, {_scope, id}}), do: to_string(id)
  def identifier_id({:via, _registry, id}), do: to_string(id)
  def identifier_id({id, _metadata}), do: to_string(id)
  def identifier_id(id), do: to_string(id)
end
