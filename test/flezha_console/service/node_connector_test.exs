defmodule FlezhaConsole.Service.NodeConnectorTest do
  @moduledoc """
  The channel the connector holds: the configuration it refuses to start
  without, the mutual TLS it reaches a controller with, and the one address of
  a name it pins and moves off when that address stops answering.

  Each test serves and stops its own listeners, so none shares one per module.
  The certificates are made by the stack's own step, `priv/dev/certs.sh`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FlezhaConsole.FakeListener
  alias FlezhaConsole.Service.NodeConnector
  alias FlezhaConsole.Service.NodeManager

  @moduletag :channel
  @moduletag :capture_log
  # An HTTPS pool waits out its readiness bound for each address it cannot
  # reach, and `localhost` has two.
  @moduletag timeout: 30_000
  @token "flzt_t"

  setup_all do
    root = Path.join(System.tmp_dir!(), "fcon_certs_#{System.unique_integer([:positive])}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    # One authority the console trusts, and another it does not.
    dirs = %{trusted: Path.join(root, "trusted"), other: Path.join(root, "other")}
    certs!(dirs.trusted, ["localhost", "twohost", "elsewhere"])
    certs!(dirs.other, ["localhost"])
    dirs
  end

  defp certs!(dir, hosts) do
    {_out, 0} =
      System.cmd("sh", ["priv/dev/certs.sh", "channel" | hosts],
        env: [{"CHANNEL_TLS_DIR", dir}],
        stderr_to_stdout: true
      )
  end

  describe "the configuration" do
    setup %{trusted: dir}, do: FakeListener.credentials(dir)

    test "an https controller with its three files is the channel", files do
      assert %{scheme: :https, host: "flezha.example", port: 8765, tls: tls} =
               NodeConnector.channel!([url: "https://flezha.example:8765"] ++ Map.to_list(files))

      assert tls[:certfile] == files.cert
    end

    test "each missing file is named", files do
      for {key, variable} <- [
            ca: "FLEZHA_CONTROLLER_CA",
            cert: "FLEZHA_CLIENT_CERT",
            key: "FLEZHA_CLIENT_KEY"
          ] do
        config = [url: "https://flezha.example:8765"] ++ Map.to_list(Map.delete(files, key))

        assert_raise ArgumentError, ~r/^#{variable} is not set/, fn ->
          NodeConnector.channel!(config)
        end
      end
    end

    test "a file that cannot be read is named with why", files do
      config =
        [url: "https://flezha.example:8765"] ++ Map.to_list(%{files | cert: "/no/such.pem"})

      assert_raise ArgumentError, ~r/^FLEZHA_CLIENT_CERT cannot be read \(\/no\/such.pem\)/, fn ->
        NodeConnector.channel!(config)
      end
    end

    test "plain HTTP is taken only on loopback" do
      assert %{scheme: :http, tls: nil} = NodeConnector.channel!(url: "http://127.0.0.1:8765")
      assert %{scheme: :http} = NodeConnector.channel!(url: "http://[::1]:8765")

      assert_raise ArgumentError, ~r/plain HTTP is accepted only on 127.0.0.1 or \[::1\]/, fn ->
        NodeConnector.channel!(url: "http://10.0.0.5:8765")
      end
    end

    test "no URL, or one that is neither https nor http, is refused" do
      assert_raise ArgumentError, ~r/^FLEZHA_CONTROLLER_URL is not set/, fn ->
        NodeConnector.channel!([])
      end

      assert_raise ArgumentError, ~r/^FLEZHA_CONTROLLER_URL must be https/, fn ->
        NodeConnector.channel!(url: "ftp://flezha.example:21")
      end
    end
  end

  describe "mutual TLS" do
    test "a controller whose certificate the authority signed is reached over HTTP/2",
         %{trusted: dir} do
      controller = FakeListener.start!(tls: {dir, "localhost"})

      assert {:ok, %{rows: []}} = NodeManager.list_namespaces(@token)

      assert [[%{token: @token}]] =
               FakeController.calls(controller, {Flezha.Service.Relay, :list_namespaces})

      assert NodeManager.connected_node() == "localhost"
    end

    test "a certificate from another authority is refused, and the log names it",
         %{trusted: trusted, other: other} do
      controller = FakeListener.start!(tls: {other, "localhost"}, point: false)

      log =
        capture_log(fn ->
          FakeListener.point_at(controller, FakeListener.credentials(trusted), false)
        end)

      assert log =~ ~r/unknown ca/i
      assert NodeManager.connected_node() == nil
      assert {:error, :node_not_connected} = NodeManager.list_namespaces(@token)
      assert FakeController.calls(controller, {Flezha.Service.Relay, :list_namespaces}) == []
    end

    test "a certificate naming another host is refused", %{trusted: dir} do
      controller = FakeListener.start!(tls: {dir, "elsewhere"}, point: false)

      log =
        capture_log(fn ->
          FakeListener.point_at(
            %{controller | url: "https://localhost:#{controller.port}"},
            %{},
            false
          )
        end)

      assert log =~ ~r/hostname|handshake/i
      assert NodeManager.connected_node() == nil
    end
  end

  describe "one controller of a name" do
    setup do
      # `twohost` resolves to two loopback addresses, as a DNS name for every
      # controller resolves to each of theirs.
      lookup = :inet_db.res_option(:lookup)
      :inet_db.set_lookup([:file, :native])

      for address <- [{127, 0, 0, 2}, {127, 0, 0, 3}],
          do: :inet_db.add_host(address, [~c"twohost"])

      on_exit(fn ->
        for address <- [{127, 0, 0, 2}, {127, 0, 0, 3}], do: :inet_db.del_host(address)
        :inet_db.set_lookup(lookup)
      end)
    end

    test "every call goes to the pinned controller, and to the other once it stops",
         %{trusted: dir} do
      first = FakeListener.start!(tls: {dir, "twohost"}, ip: {127, 0, 0, 2})

      second =
        FakeListener.start!(
          tls: {dir, "twohost"},
          ip: {127, 0, 0, 3},
          port: first.port,
          point: false
        )

      for _ <- 1..3, do: NodeManager.list_namespaces(@token)
      assert length(FakeController.calls(first, {Flezha.Service.Relay, :list_namespaces})) == 3
      assert FakeController.calls(second, {Flezha.Service.Relay, :list_namespaces}) == []

      Phoenix.PubSub.subscribe(FlezhaConsole.PubSub, NodeConnector.topic())
      FakeListener.stop(first)
      assert {:error, :node_not_connected} = NodeManager.list_namespaces(@token)

      # Down until the other address answers, then up on it.
      assert NodeConnector.reconnect()
      assert_received :controller_down
      assert_received :controller_up
      assert %{address: "127.0.0.3"} = NodeConnector.target()
      assert NodeManager.connected_node() == "twohost"

      assert {:ok, _rows} = NodeManager.list_namespaces(@token)
      assert [_] = FakeController.calls(second, {Flezha.Service.Relay, :list_namespaces})
    end
  end

  describe "a controller that goes away" do
    test "is nil while away, and answers the next call once back" do
      controller = FakeListener.start!()
      FakeListener.stop(controller)

      assert {:error, :node_not_connected} = NodeManager.list_namespaces(@token)
      refute NodeConnector.reconnect()
      assert NodeManager.connected_node() == nil

      back = FakeListener.start!(port: controller.port, point: false)
      assert NodeConnector.reconnect()
      assert {:ok, _rows} = NodeManager.list_namespaces(@token)
      assert [_] = FakeController.calls(back, {Flezha.Service.Relay, :list_namespaces})
    end

    test "a stream opened while it is away ends as unreachable", %{trusted: dir} do
      controller = FakeListener.start!(tls: {dir, "localhost"})
      FakeListener.stop(controller)

      assert {:ok, request} = NodeManager.log_tail(:audit, %{}, @token, self())
      # A probe tries every address of the name, so it ends after the stream's
      # one attempt at the pinned address.
      refute NodeConnector.reconnect()
      assert_received {:flezha_stream, _id, _result} = message
      assert {:ended, {:error, :node_not_connected}} = NodeManager.stream_result(message, request)

      # Back, so the connector's own retries end before the next test.
      FakeListener.start!(tls: {dir, "localhost"}, port: controller.port, point: false)
      assert NodeConnector.reconnect()
    end

    test "broadcasts down and up as the channel goes and comes" do
      Phoenix.PubSub.subscribe(FlezhaConsole.PubSub, NodeConnector.topic())
      controller = FakeListener.start!()
      assert_receive :controller_up

      FakeListener.stop(controller)
      refute NodeConnector.reconnect()
      assert_receive :controller_down
    end
  end
end
