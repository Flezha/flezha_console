defmodule FlezhaConsole.FakeListener do
  @moduledoc """
  Serves `FakeController` over the controller's channel, inside the test VM: a
  Plug on Bandit at `127.0.0.1` on an ephemeral port, plain HTTP, which a
  loopback controller is allowed.

  It answers as core's `http_api` does. `POST /v1/call/<operation>` applies
  the stand-in to the JSON arguments as they crossed the wire and answers its
  value as core's JSON, or its error object with the status of its class.
  `POST /v1/stream/<operation>` holds the stand-in open and writes each event
  it emits as a server-sent event, the response opened by the first event or
  by `:attached` or once it has been held a heartbeat, and ends with `end`. A
  refusal the stand-in answers at once is a plain error response. `GET
  /v1/catalogue` without a token is the 401 the console's probe expects.

  A stream the test ends with `FakeController.end_stream/3` answering
  `:overrun` is cut with `overrun`, as core cuts a client that fell behind; one
  answering `:drop` loses its connection. A call answered `{:raw, status,
  body}` is answered with that body as it is, which no controller sends.

  `start!/0` is called from a test module's shared setup, and points the
  console's channel at the listener until the module ends.
  """

  @behaviour Plug

  import Plug.Conn

  alias FlezhaConsole.Service.NodeConnector
  alias FlezhaConsole.TestEnv

  # Short, so a stream whose client went away is noticed at once.
  @heartbeat_ms 50

  @statuses %{
    invalid: 400,
    denied: 403,
    not_found: 404,
    conflict: 409,
    unavailable: 503,
    unreachable: 502,
    internal: 500
  }

  @call_kinds [:call, :answered, :timed_out, :refused]

  @doc """
  Starts a listener with a store of its own, points the console's channel at
  it and waits until the console reaches it. Answers the handle
  `FakeController` takes: `%{url:, store:}`, with the credentials a console
  reaching it presents.

    * `:tls` — `{dir, host}`: serve HTTPS as core's `http_api` does over mutual
      TLS, presenting `dir`'s certificate for `host` and accepting only clients
      `dir`'s authority signed, as `rel/overlays/bin/certs channel` makes them; the
      URL then names `host`, and the console presents `dir`'s `console`
      certificate;
    * `:ip`, `:port` — where to listen, by default 127.0.0.1 and any free port;
    * `:point` — `false` to leave the console's channel where it is.
  """
  def start!(opts \\ []) do
    store = :ets.new(:fake_controller, [:public, :set])
    {scheme, tls, host, credentials} = served(opts[:tls], opts[:ip])
    {files, transport} = Keyword.split(tls, [:certfile, :keyfile])

    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         [
           plug: {__MODULE__, %{store: store}},
           scheme: scheme,
           ip: opts[:ip] || {127, 0, 0, 1},
           port: opts[:port] || 0,
           startup_log: false,
           # A held request must not hold up the module's end.
           thousand_island_options: [shutdown_timeout: 100, transport_options: transport]
         ] ++ files},
        id: {__MODULE__, store}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    controller =
      Map.merge(%{url: "#{scheme}://#{host}:#{port}", store: store, port: port}, credentials)

    if Keyword.get(opts, :point, true), do: point_at(controller)
    controller
  end

  defp served(nil, ip),
    do: {:http, [], ip |> Kernel.||({127, 0, 0, 1}) |> :inet.ntoa() |> to_string(), %{}}

  defp served({dir, host}, _ip) do
    tls = [
      certfile: Path.join(dir, "#{host}.pem"),
      keyfile: Path.join(dir, "#{host}.key"),
      cacertfile: Path.join(dir, "ca.pem"),
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      versions: [:"tlsv1.3"]
    ]

    {:https, tls, host, credentials(dir)}
  end

  @doc "The files a console presents from `dir`, as `rel/overlays/bin/certs channel` makes them."
  def credentials(dir),
    do: %{
      ca: Path.join(dir, "ca.pem"),
      cert: Path.join(dir, "console.pem"),
      key: Path.join(dir, "console.key")
    }

  @doc """
  Points the console's channel at `controller` with `credentials` (its own by
  default), and restores it when the test or module ends. Unless `wait` is
  false, waits until the console reaches it.
  """
  def point_at(controller, credentials \\ %{}, wait \\ true) do
    config =
      [url: controller.url] ++
        for key <- [:ca, :cert, :key],
            value = Map.get(credentials, key, controller[key]),
            do: {key, value}

    previous = NodeConnector.channel!()
    TestEnv.put_app(:controller, config)

    if String.starts_with?(controller.url, "https"),
      do: swap_pool(NodeConnector.channel!(), previous)

    ExUnit.Callbacks.on_exit(fn -> NodeConnector.reconnect() end)
    reached? = NodeConnector.reconnect()
    if wait, do: true = reached?
    :ok
  end

  # The console's pool is made for the channel it boots with, plain HTTP in
  # tests; an HTTPS one is swapped in, and the previous one swapped back after.
  defp swap_pool(channel, previous) do
    replace_pool(NodeConnector.finch_spec(channel))
    ExUnit.Callbacks.on_exit(fn -> replace_pool(NodeConnector.finch_spec(previous)) end)
  end

  # The connector is paused between its messages, so no retry of its own is
  # using the pool while it is replaced.
  defp replace_pool(spec) do
    id = NodeConnector.finch()
    :ok = :sys.suspend(NodeConnector)
    :ok = Supervisor.terminate_child(FlezhaConsole.Supervisor, id)
    :ok = Supervisor.delete_child(FlezhaConsole.Supervisor, id)
    {:ok, _pid} = Supervisor.start_child(FlezhaConsole.Supervisor, spec)
    :ok = :sys.resume(NodeConnector)
  end

  @doc "Stops `controller`'s listener, as a controller that went away."
  def stop(%{store: store}), do: ExUnit.Callbacks.stop_supervised({__MODULE__, store})

  # ---- Plug ----

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, %{store: store}) do
    Process.put(FakeController, store)

    case {conn.method, conn.path_info, bearer(conn)} do
      {"GET", ["v1", "catalogue"], nil} ->
        refuse(conn, "authz.principal_not_bound", 401)

      {"POST", ["v1", route, name], token} when route in ["call", "stream"] and token != nil ->
        {:ok, body, conn} = read_body(conn)
        context = %{source: :http, token: token}
        args = Jason.decode!(body)

        if route == "call",
          do: answer(conn, Flezha.Service.Admin.run(name, args, context, :given)),
          else: stream(conn, name, args, context, store)

      {_method, _path, nil} ->
        refuse(conn, "authz.principal_not_bound", 401)

      _other ->
        send_resp(conn, 404, "")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _none -> nil
    end
  end

  defp answer(conn, {:ok, {:raw, status, body}}), do: send_resp(conn, status, body)
  defp answer(conn, {:ok, value}), do: send_json(conn, 200, Jason.encode!(wire(value)))
  defp answer(conn, {:error, error}), do: send_error(conn, error)

  defp refuse(conn, code, status) do
    {:error, error} = FakeController.error(code)
    send_error(conn, error, status)
  end

  defp send_error(conn, error, status \\ nil) do
    send_json(
      conn,
      status || Map.fetch!(@statuses, error.class),
      Jason.encode!(%{error: object(error)})
    )
  end

  defp send_json(conn, status, json) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, json)
  end

  defp object(error),
    do: %{
      code: error.code,
      class: error.class,
      message: error.message,
      details: wire(error.details),
      hint: error.hint
    }

  # ---- Streams ----

  defp stream(conn, name, args, context, store) do
    holder = self()

    task =
      Task.async(fn ->
        Process.put(FakeController, store)
        Flezha.Service.Admin.run(name, args, Map.put(context, :emit, holder), :given)
      end)

    relay(conn, task, name)
  end

  defp relay(conn, %Task{ref: ref} = task, name) do
    receive do
      {:flezha_emit, :attached} ->
        relay(open(conn), task, name)

      {:flezha_emit, event} ->
        {event_name, object} = event(name, event)
        write(open(conn), frame(event_name, Jason.encode!(object)), task, name)

      {^ref, answer} ->
        Process.demonitor(ref, [:flush])
        finish(conn, answer)

      # The handler traps exits, so the listener stopping arrives as a message.
      {:EXIT, _from, _reason} ->
        Task.shutdown(task, :brutal_kill)
        drop()
    after
      # Opened once held, unlike core, so a client that leaves is noticed over
      # HTTP/1.1, where nothing else tells an unopened response.
      @heartbeat_ms -> write(open(conn), ":\n\n", task, name)
    end
  end

  defp write(conn, data, task, name) do
    case chunk(conn, data) do
      {:ok, conn} ->
        relay(conn, task, name)

      {:error, _closed} ->
        Task.shutdown(task, :brutal_kill)
        conn
    end
  end

  defp open(%Plug.Conn{state: :chunked} = conn), do: conn

  defp open(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  defp finish(_conn, {:ok, :drop}), do: drop()

  defp finish(conn, {:ok, :overrun}) do
    {:ok, conn} = conn |> open() |> chunk(frame("overrun", ~s({"pending":1001})))
    conn
  end

  defp finish(conn, {:ok, value}) do
    {:ok, conn} =
      conn |> open() |> chunk(frame("end", Jason.encode!(%{answer: wire(value)})))

    conn
  end

  defp finish(%Plug.Conn{state: :chunked} = conn, {:error, error}) do
    {:ok, conn} = chunk(conn, frame("end", Jason.encode!(%{error: object(error)})))
    conn
  end

  defp finish(conn, {:error, error}), do: send_error(conn, error)

  defp frame(name, data), do: "event: #{name}\ndata: #{data}\n\n"

  @doc false
  # The connection lost, as a controller that went away loses it: the handler
  # ends at once, which closes its socket, with nothing written and nothing
  # logged.
  def drop, do: Process.exit(self(), :kill)

  # An event as core's `Flezha.Service.Admin.event/2` writes it.
  defp event(_operation, {kind, %Flezha.Error{} = error, metadata}),
    do:
      {Atom.to_string(kind),
       kind |> framed(metadata) |> wire() |> Map.put("error", object(error))}

  defp event(_operation, {:tally, totals, read}),
    do: {"tally", wire(Map.merge(%{kind: :tally, totals: totals}, read))}

  defp event(_operation, {kind, payload, metadata}) when is_binary(payload) do
    payload =
      if String.valid?(payload),
        do: %{payload: payload},
        else: %{payload_base64: Base.encode64(payload)}

    {Atom.to_string(kind), wire(Map.merge(framed(kind, metadata), payload))}
  end

  defp event("Observability.tail", %{} = signal),
    do:
      {"signal",
       wire(Map.take(signal, [:kind, :source, :name, :node, :at_us, :measurements, :metadata]))}

  defp event(_operation, %{} = record), do: {"log", wire(record)}

  defp framed(kind, metadata) do
    framed = %{kind: kind, channel: metadata["channel"], metadata: metadata}
    if kind in @call_kinds, do: Map.put(framed, :call, metadata["flz.call_id"]), else: framed
  end

  # A value as core's channel writes it: see `Flezha.Service.Admin.json/1` in core.
  defp wire(term) when is_binary(term) do
    if String.valid?(term), do: term, else: %{"base64" => Base.encode64(term)}
  end

  defp wire(term) when is_tuple(term), do: term |> Tuple.to_list() |> wire()
  defp wire(term) when is_list(term), do: Enum.map(term, &wire/1)
  defp wire(%MapSet{} = term), do: term |> MapSet.to_list() |> wire()
  defp wire(%Flezha.Error{} = error), do: object(error)

  defp wire(%_{} = term) do
    if Jason.Encoder.impl_for(term) == Jason.Encoder.Any,
      do: term |> Map.from_struct() |> wire(),
      else: term
  end

  defp wire(%{} = term), do: Map.new(term, fn {k, v} -> {key(k), wire(v)} end)
  defp wire(term) when is_atom(term) and term not in [nil, true, false], do: Atom.to_string(term)
  defp wire(term) when is_pid(term) or is_reference(term) or is_function(term), do: inspect(term)
  defp wire(term), do: term

  defp key(nil), do: "nil"
  defp key(key) when is_binary(key), do: key
  defp key(key) when is_atom(key) or is_number(key), do: to_string(key)
  defp key(key), do: inspect(key)
end
