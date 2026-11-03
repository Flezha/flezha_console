defmodule FlezhaConsole.Service.NodeConnector do
  @moduledoc """
  Holds the console's channel to the controller `FLEZHA_CONTROLLER_URL` names.

  The URL's host is resolved, and the first address that answers is pinned and
  kept while it answers, so every call and stream goes to one controller. An
  unauthenticated `GET /v1/catalogue` every retry interval is the probe: any
  HTTP answer, the 401 it gets without a token included, proves the controller
  reachable without spending a token. When the pinned address stops answering,
  the channel is down until another address of the name answers.

  `:controller_up` and `:controller_down` are broadcast on `topic/0` as the
  channel comes and goes. TLS checks the server's certificate against the
  configured host name, also when the connection goes to a pinned address.
  """

  use GenServer
  require Logger

  @pubsub FlezhaConsole.PubSub
  @topic "flezha:controller"
  @target {__MODULE__, :target}
  @name {__MODULE__, :name}
  @finch __MODULE__.Finch
  @default_retry_interval_ms 3_000
  # How long a request waits for a connection: an HTTP/2 pool whose
  # controller went away waits for it to come back otherwise.
  @connect_wait_ms 2_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The PubSub topic `:controller_up` and `:controller_down` are broadcast on."
  def topic, do: @topic

  @doc "The Finch pool every request to the controller is made through."
  def finch, do: @finch

  @doc "Sends `request` through the channel's pool, waiting `receive_timeout` ms for the answer."
  def request(request, receive_timeout),
    do:
      Finch.request(request, @finch,
        receive_timeout: receive_timeout,
        pool_timeout: @connect_wait_ms
      )

  @doc """
  Opens `request` as a stream through the channel's pool: `{:ok, ref}` for the
  messages `Finch.async_request/3` sends, or `{:error, error}` when no
  connection could be had.
  """
  def async_request(request) do
    {:ok,
     Finch.async_request(request, @finch,
       receive_timeout: :infinity,
       request_timeout: :infinity,
       pool_timeout: @connect_wait_ms
     )}
  rescue
    # Unlike `Finch.request/3`, an async request raises when no pool can serve
    # it, as while the pinned controller is restarting.
    error in Finch.Error -> {:error, error}
  end

  @doc """
  The pinned controller as `%{base:, host:}`, `base` the URL requests are made
  to, or `nil` while no address answers.
  """
  def target, do: :persistent_term.get(@target, nil)

  @doc """
  The name of the controller the channel reaches: the one its latest
  `Controller.controllers` answer marked `local?`, or the URL's host before
  any; `nil` while the channel is down.
  """
  def controller do
    case target() do
      nil -> nil
      %{host: host} -> :persistent_term.get(@name, nil) || host
    end
  end

  @doc "Records `name` as the controller the channel reaches, from its own `local?` row."
  def name_controller(name) when is_binary(name) do
    if target() != nil and :persistent_term.get(@name, nil) != name,
      do: :persistent_term.put(@name, name)

    :ok
  end

  @doc """
  Probes the controller now and answers whether the channel is up. A call that
  could not reach the pinned controller asks for this, so the channel moves to
  another address without waiting out the retry interval.
  """
  def reconnect, do: GenServer.call(__MODULE__, :probe, 30_000)

  @doc "As `reconnect/0`, without waiting for the answer."
  def lost, do: GenServer.cast(__MODULE__, :probe)

  @doc """
  The channel `config` describes, as `%{scheme:, host:, port:, tls:}`, or
  raises naming the environment variable that is missing or wrong: the URL
  must be `https`, with the three files readable, or plain `http` on a
  loopback address.
  """
  def channel!(config \\ Application.get_env(:flezha_console, :controller, [])) do
    url = present(config[:url]) || refuse("FLEZHA_CONTROLLER_URL", "is not set")
    uri = URI.parse(url)
    host = present(uri.host) || refuse("FLEZHA_CONTROLLER_URL", "names no host: #{url}")

    case uri.scheme do
      "https" ->
        tls = [
          cacertfile: readable!(config[:ca], "FLEZHA_CONTROLLER_CA"),
          certfile: readable!(config[:cert], "FLEZHA_CLIENT_CERT"),
          keyfile: readable!(config[:key], "FLEZHA_CLIENT_KEY")
        ]

        %{scheme: :https, host: host, port: uri.port, tls: tls}

      "http" ->
        if loopback?(host),
          do: %{scheme: :http, host: host, port: uri.port, tls: nil},
          else:
            refuse(
              "FLEZHA_CONTROLLER_URL",
              "is plain HTTP off loopback (#{url}): plain HTTP is accepted only on " <>
                "127.0.0.1 or [::1], any other controller needs https"
            )

      _other ->
        refuse("FLEZHA_CONTROLLER_URL", "must be https://host:port: #{url}")
    end
  end

  @doc """
  The Finch pool `channel` is reached through: HTTP/2 over TLS 1.3 with the
  console's client certificate, checking the server's against the authority
  and the URL's host, or HTTP/1.1 on loopback.
  """
  def finch_spec(channel), do: {Finch, name: @finch, pools: %{default: pool(channel)}}

  # A pinned address may be IPv6; Mint falls back to IPv4 for the others.
  defp pool(%{tls: nil, host: host}),
    do: [protocols: [:http1], conn_opts: [hostname: host, transport_opts: [inet6: true]]]

  defp pool(%{tls: tls, host: host}) do
    [
      protocols: [:http2],
      conn_opts: [
        hostname: host,
        transport_opts: [verify: :verify_peer, versions: [:"tlsv1.3"], inet6: true] ++ tls
      ]
    ]
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  defp readable!(path, variable) do
    path = present(path) || refuse(variable, "is not set: an https controller URL needs it")

    case File.read(path) do
      {:ok, _contents} ->
        path

      {:error, reason} ->
        refuse(variable, "cannot be read (#{path}): #{:file.format_error(reason)}")
    end
  end

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> false
    end
  end

  defp refuse(variable, problem), do: raise(ArgumentError, "#{variable} #{problem}")

  # ---- Server ----

  @impl true
  def init(_opts) do
    clear()
    {:ok, %{timer: nil, reason: nil}, {:continue, :probe}}
  end

  @impl true
  def handle_continue(:probe, state), do: {:noreply, probe(state)}

  @impl true
  def handle_call(:probe, _from, state) do
    state = probe(state)
    {:reply, target() != nil, state}
  end

  @impl true
  def handle_cast(:probe, state), do: {:noreply, probe(state)}

  @impl true
  def handle_info(:probe, state), do: {:noreply, probe(%{state | timer: nil})}

  @impl true
  def terminate(_reason, _state), do: clear()

  defp probe(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    state =
      case channel() do
        {:ok, channel} -> probe(channel, target(), state)
        {:error, reason} -> down(state, reason)
      end

    %{state | timer: Process.send_after(self(), :probe, retry_interval())}
  end

  # The pinned address first, so it is kept while it answers.
  defp probe(channel, pinned, state) do
    with {:ok, pinned} <- pinned_here(channel, pinned),
         :ok <- answers(channel, pinned.address) do
      state
    else
      :none ->
        search(channel, resolve(channel), state, "no address answers")

      {:error, reason} ->
        search(channel, resolve(channel) -- [pinned.address], down(state, reason), reason)
    end
  end

  defp pinned_here(channel, %{host: host, port: port} = pinned)
       when host == channel.host and port == channel.port,
       do: {:ok, pinned}

  defp pinned_here(_channel, _pinned), do: :none

  defp search(_channel, [], state, reason), do: down(state, reason)

  defp search(channel, [address | rest], state, _last) do
    case answers(channel, address) do
      :ok -> up(channel, address, state)
      {:error, reason} -> search(channel, rest, state, "#{address}: #{reason}")
    end
  end

  defp answers(channel, address) do
    case :get
         |> Finch.build(base(channel, address) <> "/v1/catalogue")
         |> request(@connect_wait_ms) do
      {:ok, %Finch.Response{}} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp up(channel, address, state) do
    target = %{
      base: base(channel, address),
      host: channel.host,
      port: channel.port,
      address: address
    }

    :persistent_term.erase(@name)
    :persistent_term.put(@target, target)
    Logger.info("[NodeConnector] Reached the controller #{channel.host} at #{target.base}")
    Phoenix.PubSub.broadcast(@pubsub, @topic, :controller_up)
    %{state | reason: nil}
  end

  # Logged once per change of reason, so a controller that stays away does not
  # write a line every retry.
  defp down(state, reason) do
    was_up? = target() != nil
    clear()

    if was_up? or reason != state.reason do
      Logger.warning(
        "[NodeConnector] Cannot reach the controller: #{reason}. Retrying every #{retry_interval()} ms"
      )
    end

    if was_up?, do: Phoenix.PubSub.broadcast(@pubsub, @topic, :controller_down)
    %{state | reason: reason}
  end

  defp clear do
    :persistent_term.erase(@target)
    :persistent_term.erase(@name)
  end

  defp channel do
    {:ok, channel!()}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp resolve(%{host: host}) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} ->
        [host]

      {:error, :einval} ->
        for family <- [:inet, :inet6],
            {:ok, addresses} <- [:inet.getaddrs(String.to_charlist(host), family)],
            address <- addresses,
            do: address |> :inet.ntoa() |> to_string()
    end
  end

  defp base(%{scheme: scheme, port: port}, address) do
    shown = if String.contains?(address, ":"), do: "[#{address}]", else: address
    "#{scheme}://#{shown}:#{port}"
  end

  defp retry_interval,
    do:
      Application.get_env(
        :flezha_console,
        :node_connector_retry_interval_ms,
        @default_retry_interval_ms
      )
end
