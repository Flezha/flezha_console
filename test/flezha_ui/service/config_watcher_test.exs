defmodule FlezhaUi.Service.ConfigWatcherTest do
  @moduledoc """
  The dev console's config watcher, driven with file events as live reload's
  monitor sends them and a stop function that reports instead of stopping.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias FlezhaUi.Service.ConfigWatcher

  @root "/flezha_ui"
  @files for file <- ~w(mix.exs mix.lock config/config.exs config/dev.exs),
             do: Path.join(@root, file)

  # Stands in for live reload's file monitor: answers `FileSystem.subscribe/1`
  # and tells the test who subscribed. Not linked, so a test can kill it.
  defp start_monitor(test_pid) do
    name = :"monitor_#{System.unique_integer([:positive])}"

    pid =
      spawn(fn ->
        Process.register(self(), name)
        send(test_pid, :monitor_up)

        receive do
          {:"$gen_call", {from, _tag} = reply_to, :subscribe} ->
            GenServer.reply(reply_to, :ok)
            send(test_pid, {:subscribed, from})
            receive do: (:never -> :ok)
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive :monitor_up
    {name, pid}
  end

  # By default a settle time no test waits out: a test settles the watcher
  # itself, with the token of the timer a write armed.
  defp start_watcher(opts \\ []) do
    test_pid = self()
    {monitor, _pid} = Keyword.get_lazy(opts, :monitor, fn -> start_monitor(test_pid) end)

    watcher =
      start_supervised!(
        {ConfigWatcher,
         monitor: monitor,
         files: @files,
         settle_ms: Keyword.get(opts, :settle_ms, :timer.hours(1)),
         stop: &send(test_pid, {:stopped, &1})}
      )

    assert_receive {:subscribed, ^watcher}
    watcher
  end

  # Answers the token of the settle timer the write armed, or nil for none.
  defp write(watcher, path) do
    send(watcher, {:file_event, self(), {Path.join(@root, path), [:modified, :closed]}})

    case :sys.get_state(watcher).pending do
      %{token: token} -> token
      nil -> nil
    end
  end

  defp settle(watcher, token) do
    send(watcher, {:settled, token})
    :sys.get_state(watcher)
  end

  test "a config file written stops the VM once, non-zero" do
    watcher = start_watcher()
    token = write(watcher, "config/dev.exs")

    settle(watcher, token)
    assert_received {:stopped, 1}

    settle(watcher, token)
    refute_received {:stopped, _}
  end

  test "the armed timer itself stops the VM" do
    watcher = start_watcher(settle_ms: 0)
    write(watcher, "config/dev.exs")

    assert_receive {:stopped, 1}
  end

  test "three writes of one save within the settle time stop once" do
    watcher = start_watcher()
    [first, second, last] = for _ <- 1..3, do: write(watcher, "config/config.exs")

    settle(watcher, first)
    settle(watcher, second)
    refute_received {:stopped, _}

    settle(watcher, last)
    assert_received {:stopped, 1}
    refute_received {:stopped, _}
  end

  test "mix.exs and mix.lock count as configuration" do
    watcher = start_watcher()

    settle(watcher, write(watcher, "mix.lock"))
    assert_received {:stopped, 1}

    settle(watcher, write(watcher, "mix.exs"))
    assert_received {:stopped, 1}
  end

  test "a file that is not configuration stops nothing" do
    watcher = start_watcher()

    for path <-
          ~w(lib/flezha_ui/format.ex config/notes.txt assets/config/app.exs priv/mix.exs
             config/.#dev.exs config/flycheck_dev.exs config/dev.exs~ config/prod.exs),
        do: assert(write(watcher, path) == nil)
  end

  test "a superseded settle timer is ignored" do
    watcher = start_watcher()
    settle(watcher, make_ref())

    refute_received {:stopped, _}
    assert Process.alive?(watcher)
  end

  test "by default it watches the config files Mix loaded, outside _build" do
    {monitor, _pid} = start_monitor(self())
    watcher = start_supervised!({ConfigWatcher, monitor: monitor, stop: & &1})

    files = :sys.get_state(watcher).files |> Enum.map(&Path.relative_to_cwd/1) |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new(~w(mix.exs mix.lock config/config.exs config/test.exs)),
             files
           )

    assert Enum.all?(files, &(&1 in ~w(mix.exs mix.lock) or String.starts_with?(&1, "config/")))
  end

  test "the monitor exiting ends the watcher" do
    {_name, monitor_pid} = monitor = start_monitor(self())
    watcher = start_watcher(monitor: monitor)
    ref = Process.monitor(watcher)

    Process.exit(monitor_pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}
  end

  test "the monitor stopping ends the watcher" do
    watcher = start_watcher()
    ref = Process.monitor(watcher)

    send(watcher, {:file_event, self(), :stop})

    assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}
  end

  test "with no live-reload monitor it does not start" do
    assert :ignore =
             ConfigWatcher.start_link(monitor: :no_such_monitor, stop: fn _ -> :ok end)
  end
end

defmodule FlezhaUi.Service.ConfigWatcherApplicationTest do
  @moduledoc "When the application starts the config watcher."

  # Sets application env, which every test would see.
  use ExUnit.Case, async: false

  alias FlezhaUi.Service.ConfigWatcher
  alias FlezhaUi.TestEnv

  # What `mix phx.server` amounts to for `Phoenix.Endpoint.server?/2`.
  defp serving(server?) do
    conf = Application.get_env(:flezha_ui, FlezhaUiWeb.Endpoint)
    TestEnv.put_app(FlezhaUiWeb.Endpoint, Keyword.put(conf, :server, server?))
  end

  test "starts no watcher while the flag is off" do
    serving(true)
    TestEnv.put_app(:restart_on_config_change, false)

    assert FlezhaUi.Application.config_watcher_children() == []
    assert Process.whereis(ConfigWatcher) == nil
  end

  test "starts no watcher in a VM that does not serve the endpoint" do
    serving(false)
    TestEnv.put_app(:restart_on_config_change, true)

    assert FlezhaUi.Application.config_watcher_children() == []
  end

  test "starts the watcher in the serving VM with the flag on" do
    serving(true)
    TestEnv.put_app(:restart_on_config_change, true)

    assert FlezhaUi.Application.config_watcher_children() == [ConfigWatcher]
  end
end
