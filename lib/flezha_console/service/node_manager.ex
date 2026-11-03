defmodule FlezhaConsole.Service.NodeManager do
  @moduledoc """
  The single seam between this UI and the flezha controller.

  Every call is an operation on core's published consumer surface — a
  `Flezha.Service.*` function listed in core's
  `docs/internal/api/consumers/published.txt` — sent over the controller's
  HTTPS channel as `POST /v1/call/<operation>`, and every stream is opened as
  `POST /v1/stream/<operation>`, each with the operator's token as its bearer
  token. The controller builds the caller context from that token. Each
  operation's module is spelled in full at its call site, because core
  records this console's calls by reading them from there
  (`scripts/consumer_surface.py`).

  Answers are decoded from JSON by the recorded shapes
  (`FlezhaConsole.Service.ControllerShapes`), so screens read the terms they
  always did.

  Every UI-facing function takes the flezha token as its last argument.

  Callers receive the answer — `{:ok, value}`, or `{:error, error}` with the
  controller's error read into `%{code:, class:, message:, hint:, details:}` —
  or one of the transport conditions only this node can see:

    * `{:error, :node_not_connected}` — no controller is reachable.
    * `{:error, {:api_missing, module, function, arity}}` — the controller does
      not publish the operation: console and controller versions have
      diverged.
    * `{:error, :timeout}` — the controller did not answer in time.
    * `{:error, {:remote_error, term}}` — the controller answered something
      that is neither an answer nor an error.

  `error/1` reads any of them as one map, so a screen decides how to present an
  error from its class and code and never by matching its text.
  """

  require Logger

  alias FlezhaConsole.Service.ControllerShapes
  alias FlezhaConsole.Service.NodeConnector

  @default_timeout 15_000

  # How long past a call's own deadline the console waits, so a relay that does
  # not answer in time is reported by the controller rather than as a lost one.
  @deadline_margin_ms 5_000

  # `Relay.call_channel/6`'s own default deadline.
  @channel_deadline_ms 30_000

  # A stream the controller writes nothing on, not even the comment line it
  # writes every 15 seconds while quiet, has lost its connection.
  @stream_idle_ms 60_000

  # Verified identities and shared reads, so a screen that makes several
  # controller calls on one tick does not spend a round trip re-establishing
  # who it is before each of them, and tabs of one operator share a read
  # within a tick.
  @cache :flezha_console_authz_cache
  @token_ttl_ms 30_000
  @posture_ttl_ms 2_000

  # A verification that failed for one of these is an answer about the token,
  # so it is cached. `authz.registry_unavailable` is transient and is not.
  @token_codes ~w(authz.token_malformed authz.token_unknown authz.token_revoked authz.token_expired)

  # Refusals another token remedies; any other is a role granted elsewhere.
  @needs_token @token_codes ++
                 ~w(authz.principal_not_bound authz.no_role_binding console.no_token)

  # The classes core's error catalogue gives a code.
  @classes [:invalid, :denied, :not_found, :conflict, :unavailable, :unreachable, :internal]

  @doc """
  The name of the controller the channel reaches, as text, while it is up,
  otherwise `nil`. See `NodeConnector.controller/0`.
  """
  def connected_node, do: NodeConnector.controller()

  # ---- The channel ----

  # A published operation, sent to the pinned controller with the token as
  # its bearer token. Answers the value decoded by the operation's shape, or
  # the error the controller or the transport answered.
  defp channel_call(token, module, function, args, timeout) do
    call = call(module, function, args)

    with {:ok, request} <- channel_request(token, "/v1/call/" <> call.operation, args) do
      request
      |> NodeConnector.request(timeout)
      |> response(call)
    end
  end

  # What a call or stream names, for decoding its answer and reporting its
  # refusal.
  defp call(module, function, args),
    do: %{operation: operation(module, function), module: module, function: function, args: args}

  defp channel_request(token, _path, _args) when token in [nil, ""], do: {:error, :no_token}

  defp channel_request(token, path, args) when is_binary(token) do
    case NodeConnector.target() do
      nil ->
        {:error, :node_not_connected}

      %{base: base} ->
        headers = [
          {"authorization", "Bearer " <> token},
          {"content-type", "application/json"}
        ]

        {:ok, Finch.build(:post, base <> path, headers, args |> wire() |> Jason.encode!())}
    end
  end

  defp channel_request(_token, _path, _args), do: {:error, :no_token}

  # The console's arguments as the JSON the door reads: a keyword list is an
  # object, a tuple an array, an atom its name.
  defp wire([]), do: []

  defp wire(list) when is_list(list) do
    if Keyword.keyword?(list),
      do: Map.new(list, fn {key, value} -> {Atom.to_string(key), wire(value)} end),
      else: Enum.map(list, &wire/1)
  end

  defp wire(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> wire()

  defp wire(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {wire_key(key), wire(value)} end)

  defp wire(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp wire(value), do: value

  defp wire_key(key) when is_atom(key), do: Atom.to_string(key)
  defp wire_key(key), do: key

  defp response({:ok, %Finch.Response{status: 200, body: body}}, call) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, ControllerShapes.answer(call.operation, json)}
      {:error, _invalid} -> {:error, {:remote_error, body}}
    end
  end

  defp response({:ok, %Finch.Response{status: status, body: body}}, call) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => _} = error}} -> refusal(read_error(error), call)
      _other -> {:error, {:remote_error, {status, body}}}
    end
  end

  defp response({:error, error}, _call), do: transport_error(error)

  # The door refuses an operation it does not publish with
  # `control.unknown_function`, which is the version skew a missing function is.
  defp refusal(%{code: "control.unknown_function"}, %{module: module, function: function} = call) do
    arity = length(call.args) + 1

    Logger.warning(
      "[NodeManager] The controller does not publish #{inspect(module)}.#{function}/#{arity}: " <>
        "console and controller versions have diverged."
    )

    {:error, {:api_missing, module, function, arity}}
  end

  defp refusal(%{code: "control.timeout"}, _call), do: {:error, :timeout}
  defp refusal(error, _call), do: {:error, error}

  defp transport_error(%{reason: reason}) when reason in [:timeout, :request_timeout],
    do: {:error, :timeout}

  # The connector logs why, once per change, and looks for the controller again.
  defp transport_error(_error) do
    NodeConnector.lost()
    {:error, :node_not_connected}
  end

  # The error object the channel answers, by its fields.
  defp read_error(%{"code" => code} = error) do
    %{
      code: code,
      class: Enum.find(@classes, &(Atom.to_string(&1) == error["class"])),
      message: error["message"],
      hint: error["hint"],
      details: error["details"] || %{}
    }
  end

  # ---- Errors ----

  @doc """
  Any error a call can answer, as `%{code:, class:, message:, hint:, details:}`.

  A controller error is read by its fields as the channel answered it. Its
  `details` keep the text keys core gives them, such as the option a refusal
  is about. The transport conditions get the same shape with no details, so a
  screen renders both one way.
  """
  def error({:error, reason}), do: error(reason)

  # A diagnosis finding has this shape with a `level` in place of a class.
  def error(%{code: _, message: _} = error),
    do: error |> Map.put_new(:class, nil) |> Map.put_new(:hint, nil) |> Map.put_new(:details, %{})

  def error(:node_not_connected) do
    console_error(
      "node_not_connected",
      :unavailable,
      "Not connected to a flezha controller. Screens will recover automatically once it is reachable."
    )
  end

  def error(:timeout),
    do: console_error("timeout", :unavailable, "The flezha controller did not answer in time.")

  def error(:overrun) do
    console_error(
      "overrun",
      :unavailable,
      "This console fell behind the controller's stream, which it opens again."
    )
  end

  # A read that died in this console. Its reason stays in the server log: a
  # stack carries call arguments, which can include the operator's token.
  def error(:read_failed),
    do: console_error("read_failed", :internal, "This console could not finish the read.")

  def error({:api_missing, module, function, arity}) do
    console_error(
      "api_missing",
      :internal,
      "This console and the flezha controller have diverged: the controller does not publish " <>
        "#{inspect(module)}.#{function}/#{arity}."
    )
  end

  def error({:remote_error, reason}) do
    console_error(
      "remote_error",
      :internal,
      "The flezha controller answered something this console cannot read: #{inspect(reason)}"
    )
  end

  def error({:controller_unreachable, node}) do
    console_error(
      "controller_unreachable",
      :unavailable,
      "#{node} did not answer, so its facts could not be read."
    )
  end

  def error(:no_token), do: console_error("no_token", :denied, "No flezha token was presented.")
  def error(reason), do: console_error("unexpected", :internal, "Error: #{inspect(reason)}")

  defp console_error(code, class, message),
    do: %{code: "console." <> code, class: class, message: message, hint: nil, details: %{}}

  @doc "Whether an answer is the controller refusing the caller."
  def denied?(answer), do: match?(%{class: :denied}, error(answer))

  @doc """
  Whether storing another token is what `answer` asks of the operator: none
  was sent, the controller refused the one sent, or it binds no identity.
  """
  def needs_token?(answer), do: error(answer).code in @needs_token

  @doc "Whether an answer is the controller saying what was asked for does not exist."
  def not_found?(answer), do: match?(%{class: :not_found}, error(answer))

  # ---- Identity ----
  #
  # Identity comes only from a verified token. A principal typed into this UI
  # is never sent: the controller builds the caller context from the token
  # every request carries, so the audit log names who the token proves.

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
  Verifies a flezha token with the controller's `Namespace.whoami`, called
  with the token as its bearer token.

  Answers `{:ok, %{principal:, namespace:, role:, operations:, posture:}}`:
  who the token proves, the operations its role is granted and the
  controller's enforcement posture. Or `{:error, error}` with an `authz.*`
  code. Results are cached per token for a short period; a transport failure
  or `authz.registry_unavailable` is not cached. No token makes no call.
  """
  def verify_token(token) when token in [nil, ""], do: {:error, :no_token}

  def verify_token(token) when is_binary(token) do
    case cache_get({:token, token_key(token)}) do
      {:ok, cached} ->
        cached

      :miss ->
        result = authorized_call(token, Flezha.Service.Namespace, :whoami, [])
        maybe_cache_verification(token, result)
        result
    end
  end

  def verify_token(_token), do: {:error, :no_token}

  @doc """
  The names of the operations the token's role is granted, or `nil` when every
  control should render: the posture is `:open`, or the controller answered
  no list. See `granted?/2`.
  """
  def operations(token) do
    with {:ok, %{posture: posture, operations: operations}}
         when posture != :open and is_list(operations) <- verify_token(token) do
      operations
    else
      _all -> nil
    end
  end

  @doc """
  Whether a control performing the operation `name` (`"Relay.stop"`) renders
  for `operations/1`'s answer. Advice only: the controller still judges the call.
  """
  def granted?(nil, _name), do: true
  def granted?(operations, name) when is_list(operations), do: name in operations

  @doc """
  Drops a token's cached verification, so the next call re-asks the controller.

  Called when a call is refused, so a principal whose binding was removed is
  re-verified on its next call.
  """
  def evict_token(token) when is_binary(token) do
    key = token_key(token)
    cache_delete({:token, key})
    cache_delete({:authz, key})
    cache_match_delete({{:read, key, :_}, :_, :_})
    :ok
  end

  def evict_token(_token), do: :ok

  # A published operation, judged by the controller as the token's principal.
  # A refusal evicts the token's cached verification on the way out.
  defp authorized_call(token, module, function, args, timeout \\ @default_timeout) do
    token
    |> channel_call(module, function, args, timeout)
    |> evicting(token)
  end

  @doc """
  `module.function`'s answer to `args`, read as every function here reads
  one. For the shape check's channel mode (`priv/dev/record_shapes.exs`),
  which makes each recorded read through this console's own channel.
  """
  def read(module, function, args, token), do: authorized_call(token, module, function, args)

  # The name core's catalogue gives the published `module.function`.
  defp operation(module, function),
    do: "#{module |> Module.split() |> List.last()}.#{function}"

  # As `authorized_call/4`, for a function that answers a collection: anything
  # but `{:ok, list}` or an error is reported rather than handed on.
  defp authorized_list_call(token, module, function, args) do
    case authorized_call(token, module, function, args) do
      {:ok, list} when is_list(list) -> {:ok, list}
      other -> unexpected(other)
    end
  end

  # As `authorized_list_call/4`, for a read the controller answers for the
  # whole cluster: `{:ok, %{rows:, unreachable:}}`, handed on whole.
  defp authorized_rows_call(token, module, function, args, timeout \\ @default_timeout) do
    case authorized_call(token, module, function, args, timeout) do
      {:ok, %{rows: rows, unreachable: nodes}} = answer when is_list(rows) and is_list(nodes) ->
        answer

      other ->
        unexpected(other)
    end
  end

  # A cluster answer with its rows changed by `fun`, or an error as it came.
  defp map_rows({:ok, %{rows: rows} = answer}, fun), do: {:ok, %{answer | rows: fun.(rows)}}
  defp map_rows(error, _fun), do: error

  # An answer outside the shape a caller expects: an error is handed on, and
  # anything else is reported as the controller's, rather than matched wrongly.
  defp unexpected({:error, _reason} = error), do: error
  defp unexpected(other), do: {:error, {:remote_error, other}}

  # The door answers a function's `{:ok, value, more}` as `{:ok, [value, more]}`;
  # the reads that answer two values are handed on in the function's own shape.
  defp pair({:ok, [value, more]}), do: {:ok, value, more}
  defp pair(other), do: unexpected(other)

  # ---- Streams ----

  # A published stream operation, opened on the channel's stream route by a
  # process linked to `emit_pid`. It hands `emit_pid` each server-sent event,
  # decoded by its shape, as `{:flezha_emit, event}`, and ends with the
  # operation's answer, which `stream_result/2` recognises. When `emit_pid`
  # exits, the linked process exits too, which closes the request, and the
  # controller ends the operation. With `attach?` the response opening is
  # handed on as `:attached`, which the controller writes no event for.
  defp authorized_stream(token, module, function, args, emit_pid, attach? \\ false)
       when is_pid(emit_pid) do
    call = call(module, function, args)

    with {:ok, request} <- channel_request(token, "/v1/stream/" <> call.operation, args) do
      stream = Map.merge(call, %{id: make_ref(), emit: emit_pid, attach?: attach?})

      spawn_link(fn ->
        stream = Map.put(stream, :watch, Process.monitor(emit_pid))
        send(emit_pid, {:flezha_stream, stream.id, stream(request, stream)})
      end)

      {:ok, %{id: stream.id, token: token}}
    end
  end

  @doc """
  Whether `message` is the answer of a stream `request`: `:no_response`, or
  `{:ended, result}` with the operation's answer, `{:error, :overrun}` when
  the console fell behind, or a transport error. A refusal evicts the token,
  as a refused call does.
  """
  def stream_result({:flezha_stream, id, result}, %{id: id, token: token}),
    do: {:ended, evicting(result, token)}

  def stream_result(_message, _request), do: :no_response

  defp evicting(result, token) do
    if match?({:error, _}, result) and denied?(result), do: evict_token(token)
    result
  end

  defp stream(request, stream) do
    case NodeConnector.async_request(request) do
      {:ok, ref} -> read_stream(Map.merge(stream, %{ref: ref, status: nil, buffer: "", body: ""}))
      {:error, error} -> transport_error(error)
    end
  end

  defp read_stream(%{ref: ref} = stream) do
    receive do
      {^ref, {:status, status}} ->
        read_stream(%{stream | status: status})

      {^ref, {:headers, _headers}} ->
        if stream.status == 200 and stream.attach?,
          do: send(stream.emit, {:flezha_emit, :attached})

        read_stream(stream)

      {^ref, {:data, data}} when stream.status == 200 ->
        {events, rest} = sse_events(stream.buffer <> data)
        relay_events(events, %{stream | buffer: rest})

      {^ref, {:data, data}} ->
        read_stream(%{stream | body: stream.body <> data})

      {^ref, :done} when stream.status == 200 ->
        transport_error(:closed)

      {^ref, :done} ->
        response({:ok, %Finch.Response{status: stream.status, body: stream.body}}, stream)

      {^ref, {:error, error}} ->
        transport_error(error)

      # A link carries no normal exit, so the feed is watched too.
      {:DOWN, watch, :process, _feed, _reason} when watch == stream.watch ->
        Finch.cancel_async_request(ref)
        exit(:normal)
    after
      @stream_idle_ms ->
        Finch.cancel_async_request(ref)
        transport_error(:idle)
    end
  end

  # Each event goes to the feed until the controller ends the stream: `end`
  # with the operation's answer or error, `overrun` when the console fell
  # behind.
  defp relay_events([], stream), do: read_stream(stream)

  defp relay_events([{"end", data} | _rest], stream) do
    case Jason.decode(data) do
      {:ok, %{"answer" => answer}} -> {:ok, ControllerShapes.answer(stream.operation, answer)}
      {:ok, %{"error" => %{"code" => _} = error}} -> {:error, read_error(error)}
      _other -> {:error, {:remote_error, data}}
    end
  end

  defp relay_events([{"overrun", _data} | _rest], _stream), do: {:error, :overrun}

  defp relay_events([{name, data} | rest], stream) do
    case Jason.decode(data) do
      {:ok, object} -> send(stream.emit, {:flezha_emit, event(stream.operation, name, object)})
      {:error, _invalid} -> Logger.warning("[NodeManager] Unreadable #{name} event: #{data}")
    end

    relay_events(rest, stream)
  end

  # Complete server-sent events, as `{name, data}`, and what is left of the
  # buffer after the last of them. A comment line is the controller saying it
  # is still there, and is no event.
  defp sse_events(buffer) do
    {blocks, [rest]} = buffer |> String.split(~r/\r?\n\r?\n/) |> Enum.split(-1)

    events =
      for block <- blocks,
          lines = String.split(block, ~r/\r?\n/),
          data = for("data:" <> value <- lines, do: String.replace_prefix(value, " ", "")),
          data != [] do
        name =
          Enum.find_value(lines, "message", fn
            "event:" <> name -> String.trim(name)
            _line -> nil
          end)

        {name, Enum.join(data, "\n")}
      end

    {events, rest}
  end

  # An event in the JSON form of the term the console matches, decoded by its
  # shape. A relay frame is written as an object of its kind, channel,
  # metadata and payload (`payload_base64` for bytes) or error; a tally as its
  # kind, totals and the fields of its reading; a signal and a log record as
  # their fields.
  defp event(operation, "tally" = name, %{"totals" => totals} = object),
    do:
      ControllerShapes.event(operation, name, [name, totals, Map.drop(object, ["kind", "totals"])])

  defp event(operation, name, %{"kind" => name, "metadata" => metadata} = object) do
    element =
      case object do
        %{"error" => error} -> error
        %{"payload_base64" => encoded} -> %{"base64" => encoded}
        %{"payload" => payload} -> payload
      end

    ControllerShapes.event(operation, name, [name, element, metadata])
  end

  defp event(operation, name, object), do: ControllerShapes.event(operation, name, object)

  @doc """
  Posture and bound identity together, as the layout renders them.

  Cached for the length of one refresh tick, because the layout is rendered far
  more often than the controller's answer changes.

    * `:posture` — `:open | :bootstrap_pending | :enforced` as the token's
      `whoami` answered it, or `nil` when no token verified.
    * `:principal`, `:namespace`, `:role` — the bound identity, or `nil`.
    * `:token?` — whether a token was presented at all, which separates "no
      credential" from "a credential the controller rejected".
    * `:reason` — why a presented token did not bind.
  """
  def authz_status(token) do
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
    base = %{
      posture: nil,
      principal: nil,
      namespace: nil,
      role: nil,
      token?: is_binary(token) and token != "",
      reason: nil
    }

    case verify_token(token) do
      {:ok, identity} ->
        %{
          base
          | posture: Map.get(identity, :posture),
            principal: Map.get(identity, :principal),
            namespace: Map.get(identity, :namespace),
            role: Map.get(identity, :role)
        }

      {:error, :no_token} ->
        base

      {:error, reason} ->
        %{base | reason: reason}
    end
  end

  # ---- Identity cache ----

  # Keyed by a digest rather than the token, so a crash dump or a table listing
  # cannot hand out the credential.
  defp token_key(nil), do: :none
  defp token_key(""), do: :none
  defp token_key(token) when is_binary(token), do: :crypto.hash(:sha256, token)
  defp token_key(_token), do: :none

  defp maybe_cache_verification(token, {:ok, _identity} = result) do
    cache_put({:token, token_key(token)}, result, @token_ttl_ms)
  end

  defp maybe_cache_verification(token, {:error, %{code: code}} = result)
       when code in @token_codes do
    cache_put({:token, token_key(token)}, result, @token_ttl_ms)
  end

  defp maybe_cache_verification(_token, _result), do: :ok

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

  defp cache_match_delete(pattern) do
    :ets.match_delete(@cache, pattern)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  What `token`'s read `key` holds in the read cache, as `{:ok, value}`, or
  `:miss`. Every key carries the token, so no read crosses operators.
  """
  def cached(token, key), do: cache_get({:read, token_key(token), key})

  @doc "Holds `value` as `token`'s read `key` for `ttl_ms`."
  def cache(token, key, value, ttl_ms),
    do: cache_put({:read, token_key(token), key}, value, ttl_ms)

  # `fun`'s answer, shared by every caller asking `key` with `token` within
  # `ttl_ms`; a failed read is not kept.
  defp shared_read(token, key, ttl_ms, fun) do
    case cached(token, key) do
      {:ok, answer} ->
        answer

      :miss ->
        with {:ok, _value} = answer <- fun.() do
          cache(token, key, answer, ttl_ms)
          answer
        end
    end
  end

  @doc """
  The value out of a call result, or `default` when it failed. A cluster
  answer's value is its rows; `unreachable/1` reads which controllers it lacks.

  For a screen that shows a section as empty when the controller cannot answer
  it, rather than failing the whole page.
  """
  def ok_or({:ok, value}, _default), do: rows(value)
  def ok_or({:error, _reason}, default), do: default

  @doc """
  The value out of a call result and the reason it failed, as `{value, error}`.

  `ok_or/2` for a section that only needs the value; this for one that also has
  to say why it is empty, so a screen states a refusal instead of writing the
  same two-branch `case` for every panel it loads.
  """
  def ok_or_error({:ok, value}, _default), do: {rows(value), nil}
  def ok_or_error({:error, reason}, default), do: {default, reason}

  defp rows(%{rows: rows, unreachable: _nodes}), do: rows
  defp rows(value), do: value

  @doc """
  The controllers that did not answer any of `answers`, sorted, once each.

  An answer is a call result, or a value carrying `unreachable` such as a
  `quota_usage/3` row. A screen gathers its reads' here on each refresh, so the
  partial-answer notice says what that refresh is missing.
  """
  def unreachable(answers) when is_list(answers),
    do: answers |> Enum.flat_map(&unreached/1) |> Enum.uniq() |> Enum.sort()

  defp unreached({:ok, value}), do: unreached(value)
  defp unreached(%{unreachable: nodes}) when is_list(nodes), do: nodes
  defp unreached(_answer), do: []

  @doc """
  The rows of a per-controller read that belong to `node`, as `{:ok, rows}`,
  or `{:error, {:controller_unreachable, node}}` when it did not answer.
  `node` is matched by name, so a node named in a URL finds its rows.
  """
  def of_controller({:ok, %{rows: rows, unreachable: unreachable}}, node) do
    if to_string(node) in Enum.map(unreachable, &to_string/1),
      do: {:error, {:controller_unreachable, node}},
      else: {:ok, rows_with(rows, :node, node)}
  end

  def of_controller(error, _node), do: error

  @doc """
  `node`'s own row of a read answering one row per controller, as `{:ok,
  row}`, or an error as `of_controller/2` answers one.
  """
  def controller_row(answer, node) do
    case of_controller(answer, node) do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> {:error, {:controller_unreachable, node}}
      error -> error
    end
  end

  # ---- Namespaces and relays ----

  @doc """
  The namespaces the caller may see, from the controller's durable catalog,
  as rows `%{namespace:, running:, nodes:}`: a declared namespace with no hub
  is listed too, and `running` means a hub runs on any controller, `nodes`.
  The controller narrows the listing to the caller.
  """
  def list_namespaces(token) do
    authorized_rows_call(token, Flezha.Service.Relay, :list_namespaces, [])
  end

  @doc """
  The names `list_namespaces/1` answers, sorted, as `{names, error}`.

  The read every fleet-wide screen and every namespace picker starts from, so
  two of them cannot disagree about what the bound token may see.
  """
  def scoped_namespaces(token) do
    {rows, error} = token |> list_namespaces() |> ok_or_error([])
    {rows |> Enum.map(&to_string(&1.namespace)) |> Enum.sort(), error}
  end

  @doc """
  The namespaces a screen scoped to `scope` reads, as `scoped_namespaces/1`
  answers them: that one namespace, or with no scope every one the token
  reaches.
  """
  def namespaces_in_scope(nil, token), do: scoped_namespaces(token)
  def namespaces_in_scope(scope, _token), do: {[scope], nil}

  @doc """
  A namespace's relays as listings show them, health resolved: one row each,
  with each partition group collapsed into one row carrying `partitions`
  ("3/4") and `members`, as healthy as its sickest member by the controller's
  rule. One call answers the whole cluster's relays of the namespace.

  With `opts` (`limit`, `after`, `sort`, `filter`, as `Flezha.Cluster.Page`
  takes them) it answers one page of them, `%{rows:, total:, next:,
  unreachable:, summary:}`, each row also carrying its `run` and `plugins`
  count. `summary` holds the namespace's `health` counts, `faulted_groups` and
  the factories relays are `waiting` on; an `ids`-only read answers it `nil`.
  """
  def relay_list(namespace, token, opts \\ []) do
    token
    |> authorized_rows_call(Flezha.Service.Relay, :list, with_opts([namespace], opts))
    |> map_rows(&decorate_listed/1)
  end

  defp decorate_listed(rows) do
    rows
    |> decorate_health()
    |> Enum.map(fn
      %{members: [_ | _] = members} = group -> %{group | members: decorate_health(members)}
      row -> row
    end)
  end

  @doc """
  The first `limit` relays of `namespace` whose id or factory contains
  `query`, as `relay_list/3` pages them, the first relays for a blank one:
  what a picker of relays reads as the operator types.
  """
  def search_relays(namespace, token, query, limit \\ 20),
    do: relay_list(namespace, token, limit: limit, filter: text_filter(query))

  @doc "The controller filter a typed search asks for: none for a blank one."
  def text_filter(query) do
    case query |> to_string() |> String.trim() do
      "" -> []
      text -> [text: text]
    end
  end

  # A paged read's trailing `opts`, left out when there are none, so the read
  # answers what it always did.
  defp with_opts(args, []), do: args
  defp with_opts(args, opts), do: args ++ [opts]

  # Rows with their health resolved, an absent one read as `:unknown`.
  defp decorate_health(rows), do: Enum.map(rows, &Map.put(&1, :health, row_health(&1)))

  @doc """
  The plugins bound to each relay of a namespace, as
  `[{relay_id, [{plugin_id, plugin}]}]`. A relay with none is absent.
  """
  def relay_plugins(namespace, token) do
    authorized_rows_call(token, Flezha.Service.Relay, :relay_plugins, [namespace])
  end

  @doc "`relay_id`'s row among `rows`, as `relay_list/3` answers them, or nil."
  def relay_row(rows, relay_id), do: Enum.find(rows, &(to_string(&1.id) == to_string(relay_id)))

  @doc """
  `relay_id`'s own row of `relay_list/3`, read by its id, and for a partition
  member its group's members by partition index (`[]` for any other relay),
  as `{answer, row, members}`. `row` is nil when the controller lists no such
  relay.

  A member is read with its group, whose id its own carries as the controller
  names members (`<group>#p<index>`): the controller answers a group as one
  row holding its members.
  """
  def relay_and_partitions(namespace, relay_id, token) do
    read = relay_list(namespace, token, filter: [ids: own_ids(relay_id)])
    {row, members} = read |> ok_or([]) |> own_row(relay_id)
    {read, row, members}
  end

  defp own_ids(relay_id) do
    case Regex.run(~r/^(.+)#p\d+$/, relay_id) do
      [_member, group] -> [relay_id, group]
      nil -> [relay_id]
    end
  end

  defp own_row(rows, relay_id) do
    case relay_row(rows, relay_id) do
      nil ->
        members = Enum.find_value(rows, [], & &1[:members])
        row = relay_row(members, relay_id)
        {row, if(row, do: Enum.sort_by(members, & &1.partition.index), else: [])}

      row ->
        {row, []}
    end
  end

  @doc """
  How many runners serve `factory` in `namespace`, or nil when that could not
  be read — which must never read as none.
  """
  def serving_count(namespace, factory, token) do
    case runners_for_factory(namespace, to_string(factory), token) do
      {:ok, %{rows: runners}} -> length(runners)
      {:error, _reason} -> nil
    end
  end

  @doc """
  `serving_count/3` of each of `factories`, as `%{factory => count}`, leaving
  out a factory whose count could not be read. `runners` is the namespace's
  connected runners when the caller already read them: none connected means
  none serves, at no cost.
  """
  def serving_counts(namespace, factories, token, runners \\ :unread)

  def serving_counts(_namespace, factories, _token, []), do: Map.new(factories, &{&1, 0})

  def serving_counts(namespace, factories, token, _runners) do
    factories
    |> Map.new(&{&1, serving_count(namespace, &1, token)})
    |> Map.reject(fn {_factory, count} -> is_nil(count) end)
  end

  defp builder_run(%{run: :steps}), do: :steps
  defp builder_run(_builder), do: :flow

  # Health as the Convergence Loop classifies it, in the controller's own rank
  # order. `:suspended` is a verdict like any other, so filtering to it costs
  # nothing beyond the listing's own read; `:unknown` is a row the loop has not
  # observed yet and is never rounded up to healthy.
  @health_verdicts [
    :healthy,
    :unknown,
    :suspended,
    :degraded,
    :recovering,
    :unbound,
    :failed,
    :halted
  ]

  @doc "The health verdicts a relay row can carry, in the controller's rank order."
  def health_verdicts, do: @health_verdicts

  @doc """
  A row's health, reading an absent or `nil` value as `:unknown`.

  Never `:healthy` by default: an aggregate that rounded an unobserved row up
  would hide exactly the case the column exists for.
  """
  def row_health(%{health: health}) when is_atom(health) and not is_nil(health), do: health
  def row_health(_row), do: :unknown

  @doc """
  Counts by health, `%{health => count}` as the controller's relay summary
  answers them, as `{health, count}` pairs in `health_verdicts/0` order,
  empty buckets omitted.

  A health this UI does not know is kept under its own name rather than folded
  into `:unknown` — the controller named it for a reason.
  """
  def health_pairs(counted) when is_map(counted) do
    known =
      for verdict <- @health_verdicts,
          count = Map.get(counted, verdict, 0),
          count > 0,
          do: {verdict, count}

    known ++ Enum.sort(Map.drop(counted, @health_verdicts))
  end

  @doc """
  `rows` narrowed to those whose `field` is `value`, compared as text, or left
  whole for no value.

  For a listing a call answers wider than a screen shows it: schedules carry
  the namespace the call does not take, and rows of a cluster answer the
  `node` holding them. A row carrying no value is bound to nothing a filter
  can claim, so a filter excludes it.
  """
  def rows_with(rows, _field, value) when is_list(rows) and value in [nil, ""], do: rows

  def rows_with(rows, field, value) when is_list(rows),
    do: Enum.filter(rows, &(to_string(&1[field]) == to_string(value)))

  @doc "The controllers `rows` live on, sorted, once each; a row naming none is left out."
  def row_controllers(rows) when is_list(rows),
    do: rows |> Enum.map(& &1[:node]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

  @doc """
  Rows that are copies of one thing on several controllers, folded: one
  `{row, copies}` per `key`, in the order the first copy of each is listed.
  """
  def copies(rows, key) when is_list(rows) do
    rows
    |> Enum.group_by(key)
    |> Enum.map(fn {_key, [first | _] = copies} -> {first, copies} end)
    |> Enum.sort_by(fn {first, _copies} -> Enum.find_index(rows, &(&1 == first)) end)
  end

  @doc "The rows with no live node — placed nowhere, so serving nothing."
  def unplaced_rows(rows) when is_list(rows), do: Enum.filter(rows, &is_nil(&1[:node]))

  @doc """
  The cluster's controller nodes, as `[%{name:, connected?:}]` sorted by name:
  every node holding a hub as the controller answers `hub_nodes`, and the node
  this UI reached, which is always a member even before it hosts a hub.
  `connected?` marks the node this console calls, not "the" controller.
  """
  def cluster_nodes(hub_nodes, connected) when is_list(hub_nodes) do
    hub_nodes
    |> Enum.concat(List.wrap(connected))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{name: &1, connected?: &1 == connected})
  end

  @doc """
  The bindings `relay_plugins/2`'s pairs declare for `relay_id`, one row per
  plugin as `%{plugin_id:, hooks:, provider:}`, the same row
  `hook_entries/1` makes from a running relay's hook table.
  """
  def declared_bindings(pairs, relay_id) when is_list(pairs) do
    {_relay, plugins} = List.keyfind(pairs, relay_id, 0, {relay_id, []})

    for {plugin_id, plugin} <- plugins do
      %{
        plugin_id: to_string(plugin_id),
        hooks: plugin |> Map.get(:hooks, []) |> Enum.map(&declared_hook/1),
        provider: FlezhaConsole.Format.module_name(Map.get(plugin, :provider))
      }
    end
  end

  defp declared_hook({hook, _opts}), do: to_string(hook)
  defp declared_hook(hook), do: to_string(hook)

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

  # ---- Runners and factories ----

  @doc """
  Every runner serving `namespace` anywhere in the cluster, as
  `[%{id:, node:, connected_at:, silent_ms:, late?:}]`. Never the node-local read: a fleet listing that missed the
  runners on a peer controller would present itself as the whole fleet.
  """
  def runners(namespace, token) do
    authorized_list_call(token, Flezha.Service.Fleet, :runners, [namespace])
  end

  @doc """
  The factories registered in `namespace` on every controller, each carrying
  its `run` and the controllers advertising it, `nodes`.
  """
  def factories(namespace, token) do
    authorized_rows_call(token, Flezha.Service.Fleet, :factories, [namespace])
  end

  @doc """
  Drops a runner: the controller closes its session and refuses that process
  until a runner reconnects as a different one. Answers the drop mark.
  """
  def drop_runner(namespace, runner_id, token) do
    authorized_call(token, Flezha.Service.Fleet, :drop_runner, [namespace, runner_id])
  end

  @doc """
  Lifts the drop mark on a runner's stable id on every controller, so that
  process is admitted on its next retry. Answers the lifted mark.
  """
  def readmit_runner(namespace, stable_id, token) do
    authorized_call(token, Flezha.Service.Fleet, :readmit_runner, [namespace, stable_id])
  end

  @doc """
  The namespace's standing drop marks, as `[%{stable_id:, incarnation:, pid:,
  node:, dropped_at:, dropped_by:}]`.
  """
  def dropped_runners(namespace, token) do
    authorized_list_call(token, Flezha.Service.Fleet, :dropped_runners, [namespace])
  end

  @doc "The runners serving one factory in `namespace`, on any controller, as rows of ids."
  def runners_for_factory(namespace, factory_id, token) do
    authorized_rows_call(token, Flezha.Service.Fleet, :runners_for_factory, [
      namespace,
      factory_id
    ])
  end

  @doc """
  A namespace's registered factories with the runners serving each, on every
  controller, as rows `%{id:, description:, run:, each:, on_failure:,
  declarations:, runners: [runner_id], nodes: [node], servable?: boolean}`
  sorted by id. `each` and `on_failure` are `nil` for a flow factory, and
  `declarations` is `nil` from runners that announce none.

  Every screen that names a factory reads it from here. One `factories/2` call,
  whose rows carry their runners, so a refresh tick may read it. A runner that
  disconnects while a form is open leaves `servable?` stale — the controller's
  refusal is still the authority.
  """
  def factory_catalog(namespace, token) do
    namespace |> factories(token) |> map_rows(&catalog_rows/1)
  end

  defp catalog_rows(factories),
    do: factories |> Enum.map(&factory_entry/1) |> Enum.sort_by(& &1.id)

  defp factory_entry(factory) do
    id = identifier_id(factory)

    runners =
      factory |> field(:runners) |> List.wrap() |> Enum.map(&identifier_id/1) |> Enum.sort()

    %{
      id: id,
      description: field(factory, :description),
      run: field(factory, :run),
      each: field(factory, :each),
      on_failure: field(factory, :on_failure),
      declarations: field(factory, :declarations),
      runners: runners,
      nodes: factory |> field(:nodes) |> List.wrap() |> Enum.sort(),
      servable?: runners != []
    }
  end

  @doc """
  One factory of `namespace`, whether or not an instance of it runs: its
  catalog entry (`factory_catalog/2`'s) with its announced `graph`
  (`%{channels:, tasklets:}`, each tasklet saying whether it `compensates`, or
  `nil` when its runners announce none), `disagree`, true when its runners
  announce different graphs, APIs or declarations, its `api` and the
  controllers that did not answer, `unreachable`. A factory no runner
  announces is refused as `relay.factory_unknown`.
  """
  def factory(namespace, factory_id, token) do
    case authorized_call(token, Flezha.Service.Fleet, :factory, [namespace, factory_id]) do
      {:ok, %{id: _} = row} ->
        {:ok,
         row
         |> factory_entry()
         |> Map.merge(%{
           graph: row[:graph],
           disagree: row[:disagree] == true,
           api: List.wrap(row[:api]),
           unreachable: List.wrap(row[:unreachable])
         })}

      other ->
        unexpected(other)
    end
  end

  defp field(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_other, _key), do: nil

  @doc """
  The principal the controller mints for a runner connecting to `namespace`,
  or `nil` when the controller does not say — the column is then absent rather
  than guessed.
  """
  def runner_principal(namespace, token) do
    case authorized_call(token, Flezha.Service.Fleet, :runner_caller_context, [namespace]) do
      {:ok, %{principal: principal}} when is_binary(principal) -> principal
      _unavailable -> nil
    end
  end

  @doc """
  Plugin packages installed on every controller, each with id, version,
  status and the `node` it is installed on.
  """
  def installed_plugins(token) do
    authorized_rows_call(token, Flezha.Service.Fleet, :installed_plugins, [])
  end

  # ---- Relay lifecycle ----

  @doc """
  Starts a relay. `fields` carries `factory_id` and optionally `id`,
  `init_values`, `opts`, `plugins` and `partitions`; how the relay runs is its
  factory's and is never sent. Answers `{:ok, %{id:, outcome: :started |
  :already_running}}` as the controller does.
  """
  def start_relay(namespace, fields, token) do
    relay =
      [
        factory_id: Map.fetch!(fields, :factory_id),
        init_values: Map.get(fields, :init_values, %{}),
        opts: Map.get(fields, :opts, [])
      ]
      |> put_given(:id, Map.get(fields, :id))
      |> put_given(:plugins, Map.get(fields, :plugins))
      |> put_given(:partitions, Map.get(fields, :partitions))

    authorized_call(token, Flezha.Service.Relay, :start, [namespace, relay])
  end

  defp put_given(fields, _key, value) when value in [nil, "", []], do: fields
  defp put_given(fields, key, value), do: Keyword.put(fields, key, value)

  @doc """
  The quota limits a form typed, keyed by `keys`, as `{:ok, limits}`. A blank
  field is left out, so the controller keeps its own value; any other value
  that is not a whole number of 0 or more refuses the form, naming the field.
  """
  def parse_limits(params, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, limits} ->
      typed = params |> Map.get(to_string(key)) |> to_string() |> String.trim()

      case Integer.parse(typed) do
        _blank when typed == "" -> {:cont, {:ok, limits}}
        {value, ""} when value >= 0 -> {:cont, {:ok, Map.put(limits, key, value)}}
        _invalid -> {:halt, {:error, "#{key} must be a whole number of 0 or more."}}
      end
    end)
  end

  @doc """
  A form's typed init values as the map the controller takes, or the message
  to put on the form. Blank means no init values rather than invalid ones.
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

  @doc """
  Stops a relay, or every member of the partition group it names. Answers
  `{:ok, %{id:, stopped: :stopped | :cooperative | :group}}`.
  """
  def stop_relay(namespace, relay_id, token) do
    authorized_call(token, Flezha.Service.Relay, :stop, [namespace, relay_id])
  end

  @doc """
  What is wrong with a relay and what to do about it: `%{relay:, verdict: :ok |
  :warning | :problem, findings: [%{level:, code:, message:, details:, hint:}]}`.
  Reads verdicts, runners, dead letters and the input log, so it is made on
  request, never on a refresh tick.
  """
  def diagnose_relay(namespace, relay_id, token) do
    authorized_call(token, Flezha.Service.Relay, :diagnose, [namespace, relay_id])
  end

  @doc """
  The API the relay's factory announces, as `[%{factory:, description:,
  channels: [%{channel:, codec:, schema:, description:, answer_codec:,
  answer_schema:}], disagree:, relay:}]`.
  """
  def relay_api(namespace, relay_id, token) do
    authorized_list_call(token, Flezha.Service.Relay, :api, [namespace, relay_id])
  end

  @doc """
  Sends `payload` to a relay's input `channel` (`""` for none). `opts` carries
  `key` and `msg_id`. Answers `{:ok, %{to:, verdict: :delivered | :absorbed |
  :suspended}}`.
  """
  def send_relay(namespace, relay_id, payload, channel, opts, token) do
    authorized_call(token, Flezha.Service.Relay, :send, [
      namespace,
      relay_id,
      payload,
      channel,
      opts
    ])
  end

  @doc """
  Calls a relay with `payload` and waits up to `opts[:deadline_ms]` for its
  answer, as `{:ok, %{payload:, channel:}}`.
  """
  def call_relay(namespace, relay_id, payload, channel, opts, token) do
    timeout = call_timeout(Keyword.fetch!(opts, :deadline_ms))

    case authorized_call(
           token,
           Flezha.Service.Relay,
           :call,
           [namespace, relay_id, payload, channel, opts],
           timeout
         ) do
      {:ok, [answer, meta]} -> {:ok, %{payload: answer, channel: Map.get(meta, "channel")}}
      other -> unexpected(other)
    end
  end

  @doc """
  Calls an entry channel the relay's API announces with `value`, answering
  `{:ok, %{answer:, answer_codec:}}` from a channel that answers and
  `{:ok, %{accepted: true}}` from one that does not.
  """
  def call_channel(namespace, relay_id, channel, value, opts, token) do
    timeout = call_timeout(Keyword.get(opts, :deadline_ms, @channel_deadline_ms))

    authorized_call(
      token,
      Flezha.Service.Relay,
      :call_channel,
      [namespace, relay_id, channel, value, opts],
      timeout
    )
  end

  @doc "How long a call with `deadline_ms` is waited on: its deadline and a margin."
  def call_timeout(deadline_ms) when is_integer(deadline_ms),
    do: deadline_ms + @deadline_margin_ms

  @doc """
  Re-runs a flow relay's cell (`<relay_class>/<tasklet>/<cell_key>`) from `from`,
  a sequence or an ISO 8601 time. Answers `{:ok, %{cell:, from_seq:}}`.
  """
  def replay_cell(namespace, cell, from, token) do
    authorized_call(token, Flezha.Service.Relay, :replay, [namespace, cell, from])
  end

  @doc """
  A relay's live cell state, narrowed by `cell` — `nil` for every cell,
  `"tasklet"` or `"tasklet/cell_key"`. Answers `{:ok, json, change_seq}`.
  """
  def cell_state(namespace, relay_id, cell, token) do
    pair(authorized_call(token, Flezha.Service.Relay, :cell_state, [namespace, relay_id, cell]))
  end

  @doc "One relay's overwatch state, as the controller holds it."
  def overwatch_state(namespace, relay_id, token) do
    authorized_call(token, Flezha.Service.Relay, :overwatch_state, [namespace, relay_id])
  end

  @doc """
  The graph of the relay's factory as its runners announce it: `%{relay:,
  factory:, graph: %{channels:, tasklets:} | nil, disagree:, reason:}`, with
  `reason: "not_announced"` when no runner announced one. A controller older
  than the graph answers `{:api_missing, …}`.
  """
  def relay_graph(namespace, relay_id, token) do
    authorized_call(token, Flezha.Service.Relay, :graph, [namespace, relay_id])
  end

  @doc """
  What each tasklet of the relay is doing, as its runner counts them:
  `%{relay:, runner:, read_at_ms:, instance_seq:, tasklets: [%{tasklet:,
  cells:, queued:, queued_max:, admitted_total:, …}], cells:}`. A figure the
  runner does not keep is `nil`.

  `opts` takes `cells_of`, a tasklet whose Cells to answer too, and `limit`:
  then `cells` is `%{tasklet:, cells_total:, rows: [%{key:, queued:,
  admitted_total:, blocked_total:, dropped_newest_total:,
  dropped_oldest_total:, last_admitted_ms:}]}`, or `nil` from a runner that
  keeps no per-Cell figures.
  """
  def relay_activity(namespace, relay_id, token, opts \\ []) do
    authorized_call(token, Flezha.Service.Relay, :activity, [namespace, relay_id, opts])
  end

  @doc """
  The facts a screen wants out of a relay's overwatch state.

  The controller answers a struct this node cannot pattern-match, and each
  field needs its own rule to read: the run falls back to the builder, the
  relay class defaults to the id, uptime is a wall-clock difference. Decoding
  it here keeps one place knowing the shape.

  `overwatch_facts/0` is the same shape with nothing in it, for a screen whose
  read failed. `feeding` is what `feeding_providers/1` answered, which decides
  the relay's `sources`.
  """
  def overwatch_facts(namespace, relay_id, token, feeding \\ nil) do
    case overwatch_state(namespace, relay_id, token) do
      {:ok, state} when is_map(state) -> {:ok, decode_overwatch(state, relay_id, feeding)}
      other -> unexpected(other)
    end
  end

  def overwatch_facts, do: decode_overwatch(%{}, nil, nil)

  defp decode_overwatch(state, relay_id, feeding) do
    started_at = Map.get(state, :started_at)

    %{
      factory_id: Map.get(state, :factory_id),
      runner_id: overwatch_runner(Map.get(state, :runner_id)),
      run: builder_run(Map.get(state, :builder) || %{}),
      suspended: Map.get(state, :phase) == :suspended,
      effectively_once: Map.get(state, :effectively_once, false),
      # Defaulted rather than required, so an older controller whose overwatch
      # omits a field decodes instead of failing.
      durable_steps: Map.get(state, :durable_steps, false),
      correction_window_ms: Map.get(state, :correction_window_ms),
      arrived_via_hotswap?: Map.get(state, :arrived_via_hotswap?, false),
      init_error: Map.get(state, :halt_reason),
      default_input_type: Map.get(state, :default_input_type),
      settings: Map.get(state, :settings),
      started_at: started_at,
      uptime_ms: uptime(started_at),
      # Changes when the relay is bound again, as on a runner reconnecting.
      bound_at: Map.get(state, :bound_at),
      relay_class: relay_class(state, relay_id),
      bindings: hook_entries(state),
      sources: entry_sources(state, feeding)
    }
  end

  defp overwatch_runner(nil), do: nil
  defp overwatch_runner(id), do: identifier_id(id)

  # A relay's class is its id unless the builder overrode it — the
  # controller's own rule, so a DLQ or state join agrees with what was written.
  defp relay_class(_state, nil), do: nil

  defp relay_class(%{builder: %{opts: opts}}, relay_id) when is_list(opts) do
    to_string(Keyword.get(opts, :relay_class, relay_id))
  end

  defp relay_class(_state, relay_id), do: to_string(relay_id)

  # `started_at` is wall-clock ms, so it stays comparable read from another node.
  defp uptime(started_at) when is_integer(started_at) do
    System.system_time(:millisecond) - started_at
  end

  defp uptime(_started_at), do: nil

  @doc """
  One row per (hook, plugin) pair from a relay's overwatch state.

  The hook table's `subs` maps each hook name to the entries subscribed to it;
  provider and position live on the entry, so this is the only place that
  knows the table's shape. `channel` is the set of channels the plugin acts
  on, as the controller resolved its channel options, or `nil` for every
  channel. `tally?` marks a listener that only counts the outputs of each
  channel and hears no record.
  """
  def hook_entries(%{extensions: table}), do: hook_entries(table)

  def hook_entries(%{subs: subs} = table) when is_map(subs) do
    subs
    |> Enum.flat_map(fn {hook, entries} ->
      entries
      |> List.wrap()
      |> Enum.map(fn entry ->
        plugin_id = to_string(Map.get(entry, :plugin_id, "—"))
        opts = plugin_opts(table, plugin_id)

        %{
          plugin_id: plugin_id,
          hook: to_string(hook),
          provider: FlezhaConsole.Format.module_name(Map.get(entry, :provider)),
          position: Map.get(entry, :position),
          channel: opts |> Map.get(:filter_channel) |> channel_names(),
          tally?: to_string(Map.get(opts, :mode)) == "tally"
        }
      end)
    end)
    |> Enum.sort_by(&{&1.hook, &1.position || 0, &1.plugin_id})
  end

  def hook_entries(_), do: []

  @doc """
  The plugins that inject records into one of the relay's entry channels, such
  as a websocket or a poll, whether or not they are bound on a hook:
  `[%{plugin_id:, provider:, channel: [entry] | []}]`, by plugin id.

  `feeding` is `feeding_providers/1`'s answer: a plugin whose provider feeds a
  relay is a source, and one naming no channel answers `channel: []`, since
  the runner routes it to the relay's first entry channel. With `nil`, from a
  controller whose listing does not say, a plugin is a source only when it
  names an entry channel.
  """
  def entry_sources(state, feeding \\ nil)

  def entry_sources(%{extensions: %{plugins: plugins} = table}, feeding) when is_map(plugins) do
    plugins
    |> Enum.flat_map(fn {plugin_id, plugin} ->
      plugin_id = to_string(plugin_id)
      provider = FlezhaConsole.Format.module_name(Map.get(plugin, :provider))
      entry = table |> plugin_opts(plugin_id) |> Map.get(:entry_channel)
      channel = if entry in [nil, ""], do: [], else: [to_string(entry)]

      if feeds?(provider, channel, feeding),
        do: [%{plugin_id: plugin_id, provider: provider, channel: channel}],
        else: []
    end)
    |> Enum.sort_by(& &1.plugin_id)
  end

  def entry_sources(_state, _feeding), do: []

  defp feeds?(_provider, channel, nil), do: channel != []
  defp feeds?(provider, _channel, feeding), do: MapSet.member?(feeding, provider)

  @doc """
  The provider modules whose plugins feed a relay, by the provider listing's
  `feeds` flag, as names `FlezhaConsole.Format.module_name/1` gives. `nil` when the
  listing cannot be read or does not carry the flag.
  """
  def feeding_providers(token) do
    case providers(token) do
      {:ok, %{rows: [_ | _] = listed}} ->
        if Enum.all?(listed, &is_map_key(&1, :feeds)),
          do: for(%{feeds: true, module: module} <- listed, into: MapSet.new(), do: module)

      _unread ->
        nil
    end
  end

  # The controller writes `entry_channel` and `filter_channel` from the
  # plugin's `channel`, `channel_in` and `channel_out` options, so they are the
  # one reading of where a plugin is attached.
  defp plugin_opts(table, plugin_id) do
    case table |> Map.get(:plugins, %{}) |> Map.get(plugin_id) do
      %{opts: %{} = opts} -> opts
      _none -> %{}
    end
  end

  defp channel_names(nil), do: nil
  defp channel_names(names), do: names |> List.wrap() |> Enum.map(&to_string/1)

  # ---- Steps relays ----

  @doc "How long a finished instance of a relay class keeps its state, in hours."
  def completed_retention_hours(relay_class, token) do
    authorized_call(token, Flezha.Service.Steps, :completed_retention_hours, [relay_class])
  end

  @doc """
  Until when the controller keeps a finished relay's state, as `{:ok,
  unix_seconds}`; `{:ok, nil}` when the run ended and its state was not
  kept; `{:error, :not_found}` when no end of it is recorded.
  """
  def kept_until(relay_id, token) do
    case authorized_call(token, Flezha.Service.Steps, :completion, [relay_id]) do
      {:ok, %{state_kept: true, expires_at: at}} when is_integer(at) -> {:ok, at}
      {:ok, %{state_kept: false}} -> {:ok, nil}
      {:ok, _none} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  A durable steps relay's task journal as the controller reports it:
  `%{entries:, outcome:}`, the entries newest first. `outcome` is the
  `%{status:, error:}` the engine ended the run with, `nil` while it runs.
  """
  def task_journal(relay_id, token, opts \\ [])

  def task_journal(relay_id, token, []) do
    with {:ok, %{entries: entries} = report} <-
           authorized_call(token, Flezha.Service.Steps, :journal, [relay_id]) do
      {:ok, %{report | entries: Enum.sort_by(entries, &Map.get(&1, :seq, 0), :desc)}}
    end
  end

  def task_journal(relay_id, token, opts),
    do: authorized_call(token, Flezha.Service.Steps, :journal, [relay_id, opts])

  @doc """
  The iterations the journal reports as committed — the only rewind targets.
  With `opts` one page of them, newest first, with the `next` cursor to the
  older ones.
  """
  def committed_iterations(relay_id, token, opts \\ [])

  def committed_iterations(relay_id, token, []) do
    authorized_list_call(token, Flezha.Service.Steps, :committed_iterations, [relay_id])
  end

  def committed_iterations(relay_id, token, opts) do
    authorized_rows_call(token, Flezha.Service.Steps, :committed_iterations, [relay_id, opts])
  end

  @doc "The input-log offset the relay's last iteration consumed, `nil` for none."
  def consumed_offset(relay_id, token) do
    authorized_call(token, Flezha.Service.Steps, :consumed_offset, [relay_id])
  end

  @doc """
  The input-log records the relay has not consumed yet. With `opts` one page
  of them by offset with their `total`; `limit: 0` reads only the total.
  """
  def input_log_undelivered(relay_id, token, opts \\ [])

  def input_log_undelivered(relay_id, token, []) do
    authorized_list_call(token, Flezha.Service.Steps, :undelivered, [relay_id])
  end

  def input_log_undelivered(relay_id, token, opts) do
    authorized_rows_call(token, Flezha.Service.Steps, :undelivered, [relay_id, opts])
  end

  @doc "The last offset written to the relay's input log, `-1` when it holds none."
  def input_log_last_offset(relay_id, token) do
    authorized_call(token, Flezha.Service.Steps, :last_offset, [relay_id])
  end

  @doc "Rescales a partition group to `target` members."
  def rescale(namespace, group_id, target, token) when is_integer(target) do
    authorized_call(token, Flezha.Service.Steps, :rescale, [namespace, group_id, target, []])
  end

  @doc "Rewinds a durable steps relay to a committed iteration, by its relay class."
  def rewind(namespace, relay_class, to_iter, token) when is_integer(to_iter) do
    authorized_call(token, Flezha.Service.Steps, :rewind, [namespace, relay_class, to_iter])
  end

  @doc """
  The cells of one relay class with persisted state, each with its sequences
  and durability counters: `%{relay_class:, cells: [...]}`. With `opts`
  (`filter: [text:]` a substring of the key) one page of them under `rows`,
  with their `total`.
  """
  def cells(relay_class, token, opts \\ []) do
    authorized_call(token, Flezha.Service.Steps, :cells, with_opts([relay_class], opts))
  end

  @doc """
  Where a cell's history stands at `target`, a sequence number or an ISO 8601
  time: the sequence it resolves to and the snapshot and change-log sizes
  behind it. `cell` is `<relay_class>/<tasklet>/<cell_key>`.
  """
  def time_travel(cell, target, token) do
    authorized_call(token, Flezha.Service.Steps, :time_travel, [cell, target])
  end

  @doc """
  A durable relay's retained input records, `%{instance:, floor:, entries:
  [%{offset:, consumed:, bytes:, channel:}]}`, never the payloads.
  """
  def inbox(instance_id, token) do
    authorized_call(token, Flezha.Service.Steps, :inbox, [instance_id])
  end

  @doc """
  A cell's outbox: durable seq, flush cursor, epoch, `pending` and `held` (both
  `nil` while its writer is not running) and the relay's `input_watermark`.
  """
  def outbox(cell, token) do
    authorized_call(token, Flezha.Service.Steps, :outbox, [cell])
  end

  @doc "Asks the cell's runner to compact its persisted state. Answers `{:ok, %{cell:}}`."
  def rotate_cell(cell, token) do
    authorized_call(token, Flezha.Service.Steps, :rotate, [cell])
  end

  @doc "Deletes a cell's write-ahead log, snapshots and outbox deduplication for good."
  def delete_cell(cell, token) do
    authorized_call(token, Flezha.Service.Steps, :delete, [cell])
  end

  @doc """
  Retains a relay class's write-ahead history for `hours` until the controller
  next boots. Answers `{:ok, %{relay_class:, hours:}}`.
  """
  def set_retention(relay_class, hours, token) when is_integer(hours) do
    authorized_call(token, Flezha.Service.Steps, :set_retention, [relay_class, hours])
  end

  # ---- Namespace administration ----

  @doc """
  Every namespace record, each `%{name:, quotas:, created_at:,
  created_by_principal:}`.

  A caller bound to one namespace may not list every record; it is answered
  with its own namespace's record, read with `get/2`, so the screen still has
  the declaration it may see.
  """
  def namespace_records(token) do
    case authorized_list_call(token, Flezha.Service.Namespace, :list, []) do
      {:ok, records} ->
        {:ok, records}

      {:error, reason} = refused ->
        with true <- denied?(reason),
             {:ok, %{namespace: own}} when is_binary(own) <- verify_token(token),
             {:ok, record} <- namespace_record(own, token) do
          {:ok, [record]}
        else
          _ -> refused
        end
    end
  end

  @doc "One namespace record."
  def namespace_record(name, token) do
    authorized_call(token, Flezha.Service.Namespace, :get, [name])
  end

  @doc "Declares a namespace. `quotas` is a map of overrides over the controller's defaults."
  def create_namespace(name, quotas, token) do
    authorized_call(token, Flezha.Service.Namespace, :create, [name, [quotas: quotas]])
  end

  @doc """
  Replaces a namespace's quota overrides. The controller replaces them whole,
  so `quotas` carries every limit the namespace keeps, not only the edited ones.
  """
  def set_namespace_quotas(name, quotas, token) when is_map(quotas) do
    authorized_call(token, Flezha.Service.Namespace, :set_quotas, [name, quotas])
  end

  # Which quota key limits which counter kind. The controller's own
  # `Quotas.counter_for/1` is private, so the inverse is carried here.
  # `:max_message_rate_per_second` limits a counter the controller does not
  # report, so there is nothing to meter it against.
  @quota_limit_keys %{
    relays: :max_relays,
    cells: :max_cells_per_relay,
    mailbox_bytes: :max_mailbox_bytes_total,
    runners: :max_runners,
    disk_bytes: :max_state_bytes
  }

  @doc """
  A namespace's counters paired with the limits that apply to them. Each
  `value` is the cluster's total and a breach is judged against it; `by_node`
  splits it per controller and `unreachable` names the controllers that did
  not count.

  `quotas` is the namespace record's quota map, or `nil` for a namespace with
  no record — every row then reports its value with no limit. Costs one call
  per counter kind: the controller exposes no bulk counter read.
  """
  def quota_usage(namespace, quotas, token) do
    kinds =
      ok_or(
        authorized_list_call(token, Flezha.Service.Namespace, :quota_kinds, []),
        Map.keys(@quota_limit_keys)
      )

    Enum.map(kinds, fn kind ->
      limit_key = Map.get(@quota_limit_keys, kind)
      limit = quotas && Map.get(quotas, limit_key)

      usage =
        case authorized_call(token, Flezha.Service.Namespace, :quota, [namespace, kind]) do
          {:ok, %{total: total} = usage} when is_integer(total) -> usage
          _unavailable -> %{total: nil, by_node: %{}, unreachable: []}
        end

      value = usage.total

      %{
        kind: kind,
        limit_key: limit_key,
        value: value,
        by_node: Map.get(usage, :by_node, %{}),
        unreachable: Map.get(usage, :unreachable, []),
        limit: limit,
        breached?: is_integer(limit) and is_integer(value) and value >= limit
      }
    end)
  end

  @doc "The principals bound to a namespace, each `%{principal:, namespace:, roles:, ...}`."
  def roles(namespace, token) do
    authorized_list_call(token, Flezha.Service.Namespace, :roles, [namespace])
  end

  @doc """
  The tokens the caller may see, each `%{id:, principal:, namespace:, role:,
  label:, status:}` — never the token itself.
  """
  def list_tokens(token) do
    authorized_list_call(token, Flezha.Service.Namespace, :tokens, [])
  end

  # ---- Plugins ----

  @doc """
  Enables the plugin `name`, and binds it to a relay in the same call when
  `fields` names one. `fields` carries `provider` (the id as text), `opts`
  (keyed by text — the controller turns only names the provider declares into
  atoms), `namespace`, and optionally `relay_id`, `hooks` (hook names) and
  `single`. Answers `{:ok, %{name:, outcome: :enabled | :already_enabled,
  bound:, lacking: [node]}}`.
  """
  def enable_plugin(name, fields, token) do
    fields =
      [
        provider: fields.provider,
        opts: Map.get(fields, :opts, %{}),
        namespace: fields.namespace
      ]
      |> plugin_fields(fields, [:relay_id, :hooks, :single])

    authorized_call(token, Flezha.Service.PluginManager, :enable, [name, fields])
  end

  @doc """
  Binds the enabled plugin `name` to `fields.relay_id` with `hooks` and
  `channel`. Answers `{:ok, :bound}` or `{:ok, :already_bound}`.
  """
  def bind_plugin(name, fields, token) do
    fields = plugin_fields([namespace: fields.namespace], fields, [:relay_id, :hooks, :channel])

    case authorized_call(token, Flezha.Service.PluginManager, :bind, [name, fields]) do
      {:ok, :ok} -> {:ok, :bound}
      {:ok, :already_bound} = bound -> bound
      other -> unexpected(other)
    end
  end

  @doc "Unbinds `relay_id` from the plugin `name`, which stays enabled. Answers `:ok`."
  def unbind_plugin(name, namespace, relay_id, token) do
    case authorized_call(token, Flezha.Service.PluginManager, :unbind, [
           name,
           [namespace: namespace, relay_id: relay_id]
         ]) do
      {:ok, :ok} -> :ok
      other -> unexpected(other)
    end
  end

  @doc """
  Changes the plugin `name`'s `opts` and, for a controller plugin, its `hooks`.
  Answers `{:ok, %{applied: :live | :restarted | :unchanged, relays:}}`.
  """
  def update_plugin(name, fields, token) do
    fields =
      plugin_fields([namespace: fields.namespace, opts: fields.opts], fields, [:hooks])

    authorized_call(token, Flezha.Service.PluginManager, :update, [name, fields])
  end

  # The optional plugin fields a form filled in, by the names the controller reads.
  defp plugin_fields(base, fields, keys) do
    Enum.reduce(keys, base, &put_given(&2, &1, Map.get(fields, &1)))
  end

  @doc "Disables the plugin `name` in `namespace`; its bindings stay. Answers `:ok`."
  def disable_plugin(name, namespace, token) do
    case authorized_call(token, Flezha.Service.PluginManager, :disable, [
           name,
           [namespace: namespace]
         ]) do
      {:error, reason} -> {:error, reason}
      _disabled -> :ok
    end
  end

  @doc """
  The plugins enabled in `namespace`, each `%{name:, provider:, relays:,
  hooks:, ...}`. With `opts` (filters `provider`, `relay` and `text`) one page
  of them by name, each row carrying at most 10 of its `relays` beside
  `relay_count`.
  """
  def plugins(namespace, token, opts \\ [])

  def plugins(namespace, token, []) do
    authorized_list_call(token, Flezha.Service.PluginManager, :enabled, [namespace])
  end

  def plugins(namespace, token, opts) do
    authorized_rows_call(token, Flezha.Service.PluginManager, :enabled, [namespace, opts])
  end

  @doc """
  The providers the cluster's controllers can enable, as rows `%{id:,
  module:, type:, feeds:, nodes:}`, `nodes` naming the controllers that can
  enable each, and how many installed packages each controller refused at
  boot: `{:ok, %{rows:, refused: %{node => count}, unreachable:}}`.
  """
  def providers(token) do
    token
    |> authorized_rows_call(Flezha.Service.Fleet, :providers, [])
    |> case do
      {:ok, listing} -> {:ok, Map.put_new(listing, :refused, %{})}
      error -> error
    end
  end

  @doc """
  One provider's help text, its type, the hooks it supports and, from a
  controller that publishes them, its `options`: one row per option an operator
  can set, each with `name`, `type`, `required` and `doc`, and `default`,
  `values`, `min`, `max`, `live` and `transient` when the option declares them.
  """
  def provider(provider_id, token) do
    authorized_call(token, Flezha.Service.Fleet, :provider, [provider_id])
  end

  # ---- Dead-letter queue ----

  @doc """
  Parked entries on every controller, nearest-to-expiry first, each with the
  `node` holding it. `nil` lists every relay class. With `opts` (`limit`,
  `after`) one page of them, newest first, with its `total` and `next`.
  """
  def dlq_list(relay_class, token, opts \\ []) do
    authorized_rows_call(
      token,
      Flezha.Service.Dlq,
      :list,
      with_opts([blank_to_nil(relay_class)], opts)
    )
  end

  @doc """
  One entry, found on whichever controller holds it, and its payload, as
  `{:ok, entry, payload}`.
  """
  def dlq_get(entry_ref, token) do
    pair(authorized_call(token, Flezha.Service.Dlq, :get, [entry_ref]))
  end

  @doc "Drops a parked entry on whichever controller holds it."
  def dlq_drop(entry_ref, token) do
    authorized_call(token, Flezha.Service.Dlq, :drop, [entry_ref])
  end

  @doc """
  Re-sends a parked payload to its relay as a new input, from whichever
  controller holds it. The controller waits out its replay grace and answers
  `{:ok, %{outcome: :removed | :re_parked, generation:}}`.
  """
  def dlq_replay(entry_ref, token) do
    authorized_call(token, Flezha.Service.Dlq, :replay, [entry_ref], 60_000)
  end

  @doc """
  Entry and byte counts per parked tasklet on every controller, keyed
  `relay_class` and `tasklet_id`, each with its `node`.
  """
  def dlq_stats(token) do
    authorized_rows_call(token, Flezha.Service.Dlq, :stats, [])
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # ---- Schedules ----

  @doc """
  Every schedule stored on any controller, joined with what the schedule hub
  holds for it: the `node` holding the definition, `fires_on`, the node that
  fires it, its `last_fire` and its `next_fire`.
  """
  def schedule_list(token) do
    authorized_rows_call(token, Flezha.Service.Schedule, :list, [])
  end

  @doc "Stores a schedule and asserts it on the hub, in one call."
  def schedule_add(fields, token) when is_map(fields) do
    authorized_call(token, Flezha.Service.Schedule, :add, [Map.to_list(fields)])
  end

  @doc """
  Forgets a schedule on whichever controller holds it and retracts it from the
  hub, in one call.
  """
  def schedule_remove(name, token) do
    authorized_call(token, Flezha.Service.Schedule, :remove, [name])
  end

  @doc """
  Fires a schedule once, now, on whichever controller holds it. Answers
  `{:ok, %{relay_id:, outcome: :spawned | :already_running}}`, `relay_id`
  being `nil` when none was started.
  """
  def schedule_run(name, token) do
    authorized_call(token, Flezha.Service.Schedule, :run, [name])
  end

  # ---- Logs ----
  #
  # Every durable log the controller keeps is a kind it declares, with the
  # filters a read takes and the columns a reader shows. Reads and the tail
  # cover every controller; files, statistics and rotation answer one row set
  # per controller, and a file is read on its own controller.

  # The most records the logs service answers to one read.
  @log_read_max 1_000

  @doc "The kinds of log the controller keeps, each with its filters and columns."
  def log_kinds(token), do: authorized_call(token, Flezha.Service.Logs, :kinds, [])

  @doc """
  A kind's records, newest first from every controller, as `{:ok, %{records:,
  next:, unreachable:}}`. `params` holds `filters`, `limit`, `since_us`,
  `until_us` and `before`, the cursor a previous answer named `next`.
  """
  def log_read(kind, params, token) when is_map(params) do
    read =
      for key <- [:filters, :since_us, :until_us, :before],
          value = params[key],
          value not in [nil, "", %{}],
          do: {key, value}

    limit = min(Map.get(params, :limit, 100), @log_read_max)
    authorized_call(token, Flezha.Service.Logs, :read, [[kind: kind] ++ read ++ [limit: limit]])
  end

  @doc "A kind's rotated files on every controller, as rows naming their `node`."
  def log_files(kind, token) do
    with {:ok, %{files: files, unreachable: unreachable}} <-
           authorized_call(token, Flezha.Service.Logs, :files, [[kind: kind]]),
         do: {:ok, %{rows: files, unreachable: unreachable}}
  end

  @doc "A kind's writer statistics, one row per controller."
  def log_stats(kind, token) do
    with {:ok, %{controllers: rows, unreachable: unreachable}} <-
           authorized_call(token, Flezha.Service.Logs, :stats, [[kind: kind]]),
         do: {:ok, %{rows: rows, unreachable: unreachable}}
  end

  @doc "Closes `node`'s current file of a kind and starts a new one."
  def log_rotate(kind, node, token) do
    authorized_call(token, Flezha.Service.Logs, :rotate, [[kind: kind, node: to_string(node)]])
  end

  @doc """
  Opens a kind's live tail of every controller for `emit_pid`, narrowed by
  `filters` as a read is. See `authorized_stream/5`.
  """
  def log_tail(kind, filters, token, emit_pid) do
    authorized_stream(
      token,
      Flezha.Service.Logs,
      :tail,
      [[kind: kind, filters: filters]],
      emit_pid
    )
  end

  @doc """
  A namespace's runs that ended, newest first: its `ended` relay history
  records, narrowed by `filters` such as `%{"relay" => id}` or
  `%{"factory" => id}`, read as `log_read/3` reads (`params` takes `limit`
  and `before`).
  """
  def ended_runs(namespace, filters, params, token) do
    filters = Map.merge(filters, %{"namespace" => namespace, "event" => "ended"})
    log_read("relay_history", Map.put(params, :filters, filters), token)
  end

  @doc """
  A relay's latest `ended` record in the relay history, `{:ok, nil}` when it
  has none.
  """
  def last_run(namespace, relay_id, token) do
    with {:ok, %{records: records}} <-
           ended_runs(namespace, %{"relay" => relay_id}, %{limit: 1}, token),
         do: {:ok, List.first(records)}
  end

  # ---- Observability ----

  @doc """
  Recent signals from every controller's observability ring buffer, newest
  last, each with the `node` that recorded it and `at_us`, the wall-clock
  time it was recorded. `params` is the service's own query — `%{source:,
  limit:, since_us:}`, `since_us` a wall-clock bound in microseconds.
  """
  def observability_query(params, token) when is_map(params) do
    authorized_rows_call(token, Flezha.Service.Observability, :query, [params])
  end

  @doc """
  How many of the controllers listing a source run it, as `{on, of}`. The
  controller carries `statuses`, one `:active` or `:disabled` per node.
  """
  def source_enabled(%{statuses: statuses}) when is_map(statuses),
    do: {Enum.count(statuses, fn {_node, status} -> status == :active end), map_size(statuses)}

  def source_enabled(_source), do: {0, 0}

  @doc """
  Whether a sink is running: a sink entry carries no enabled flag, only the
  `:pid` set while its process is up, which crosses the channel as text.
  """
  def sink_running?(sink), do: Map.get(sink, :pid) not in [nil, ""]

  @doc """
  Every source once, with its state on each controller in `statuses` and its
  recent signals counted across them.
  """
  def observability_sources(token) do
    authorized_rows_call(token, Flezha.Service.Observability, :list_sources, [])
  end

  @doc "Every controller's sinks, each with its `node`."
  def observability_sinks(token) do
    authorized_rows_call(token, Flezha.Service.Observability, :list_sinks, [])
  end

  @doc """
  Enables an observability source on every controller, answering `{:ok,
  %{applied: nodes, unreachable: nodes}}`. `source` is the name the controller
  listed, an atom or, for one this console has no atom for, its text.
  """
  def enable_source(source, token) when is_atom(source) or is_binary(source) do
    authorized_call(token, Flezha.Service.Observability, :enable_source, [to_string(source)])
  end

  @doc "As `enable_source/2`, switching it off."
  def disable_source(source, token) when is_atom(source) or is_binary(source) do
    authorized_call(token, Flezha.Service.Observability, :disable_source, [to_string(source)])
  end

  @doc "Opens a live tail of `source` on every controller for `emit_pid`. See `authorized_stream/5`."
  def observability_tail(source, token, emit_pid) when is_atom(source) or is_binary(source) do
    authorized_stream(token, Flezha.Service.Observability, :tail, [to_string(source)], emit_pid)
  end

  # ---- Listen ----

  @doc """
  Opens a listen on a relay's `:output`, `:input` or `:calls` for `emit_pid`,
  which receives `:attached` and then each frame. A `:calls` listen hands on,
  for each call the relay takes, `{:call, request, md}` and then one of
  `{:answered, answer, md}`, `{:timed_out, error, md}` or
  `{:refused, error, md}`, paired by `md["flz.call_id"]`. A `:tally` listen
  hands on, about once a second, `{:tally, %{channel => total}, %{read_at_ms:,
  epochs:}}`: the frames counted per output channel since its count started,
  which starts again whenever an `epochs` value changes. See
  `authorized_stream/5`.
  """
  def listen(namespace, relay_id, direction, token, emit_pid)
      when direction in [:output, :input, :calls, :tally] do
    authorized_stream(
      token,
      Flezha.Service.Relay,
      :listen,
      [namespace, relay_id, direction, []],
      emit_pid,
      true
    )
  end

  # ---- Controller ----
  #
  # Each controller's own facts are answered for every controller at once, one
  # row each or rows carrying their `node`; `controller_row/2` and
  # `of_controller/2` pick one controller's.

  @doc """
  Every controller's status, one row each: durability backend and posture,
  RPO breach and superseded counts, the shutdown state and configuration, and
  its `node`.
  """
  def controller_status(token) do
    authorized_rows_call(token, Flezha.Service.Controller, :status, [])
  end

  @doc "References past their RPO target on every controller, each with its `node`."
  def durability_breaches(token) do
    authorized_rows_call(token, Flezha.Service.Controller, :durability_breaches, [])
  end

  @doc """
  Every controller's readiness verdict and each running namespace's hub
  recovery state, one row each: `%{node:, readiness:, preconditions:,
  namespaces: [%{namespace:, recovery_state:}]}`.
  """
  def boot_status(token) do
    authorized_rows_call(token, Flezha.Service.Controller, :boot_status, [])
  end

  @doc """
  The durability shippers' own status, one row per shipped reference with the
  `node` shipping it: `%{ref:, last_shipped_ms:, pending_since_ms:, failures:,
  retry_after_ms:, superseded_by:, last_error:}`. Empty while no remote tier
  is configured.
  """
  def durability_status(token) do
    authorized_rows_call(token, Flezha.Service.Controller, :durability_status, [])
  end

  @doc """
  Every controller's memory hot spots, one row each. Expensive — a process
  scan on each — so it is only taken when an operator asks, never on a
  refresh tick.
  """
  def mem_top(token) do
    authorized_rows_call(token, Flezha.Service.Controller, :mem_top, [], 60_000)
  end

  @doc """
  The cluster as `namespace` sees it: its hub `nodes`, each with its relay
  count and recovery state, the unplaced relay count and the health breakdown,
  with the controllers that did not answer in `unreachable`.
  """
  def cluster_status(namespace, token) do
    authorized_call(token, Flezha.Service.Controller, :cluster_status, [namespace])
  end

  @doc """
  Every controller of the cluster, the one asked first, as rows `%{node:,
  host:, host_node:, version:, uptime_ms:, runners:, local?:, reachable?:
  true}`, or `%{node:, local?: false, reachable?: false}` for one that did not
  answer in time. `host_node` is the machine it runs on, nil when the
  controller is not told.
  """
  def controllers(token) do
    with {:ok, %{rows: rows}} = answer <-
           authorized_rows_call(token, Flezha.Service.Controller, :controllers, []) do
      for %{local?: true, node: node} <- rows,
          is_binary(node),
          do: NodeConnector.name_controller(node)

      answer
    end
  end

  @doc """
  The always-on data-plane counters of the relays `opts` name: `%{channels:
  [...], relays: [...], unreachable:}`, every value a monotonic count. Rates
  are the caller's business.

  `opts` is `filter: [relays: [{namespace, relay_id}]]` (at most 500) for
  those relays and the channels of their runners, or `filter: [namespace:
  ns], limit: 0` for that namespace's summed `totals` and no rows. A screen
  never reads the unfiltered cluster snapshot. Reads with the same token and
  `opts` within `:liveness_ttl_ms` (1.5 s unless configured) are answered
  once, so an operator's tabs on one tick share a read.
  """
  def liveness_snapshot(token, opts) do
    ttl = Application.get_env(:flezha_console, :liveness_ttl_ms, 1_500)

    shared_read(token, {:liveness, opts}, ttl, fn ->
      authorized_call(token, Flezha.Service.Controller, :liveness_counters, [opts])
    end)
  end

  @doc """
  The id out of a controller identifier, whatever shape it arrives in: a map
  carrying `id`, a bare id, an `{id, metadata}` pair, or the `:via` tuple a
  process registered through the controller's process registry is named by.
  """
  def identifier_id(%{id: id}), do: to_string(id)
  def identifier_id(%{"id" => id}), do: to_string(id)
  def identifier_id({:via, _registry, {_scope, id}}), do: to_string(id)
  def identifier_id({:via, _registry, id}), do: to_string(id)
  def identifier_id({id, _metadata}), do: to_string(id)
  def identifier_id(id), do: to_string(id)
end
