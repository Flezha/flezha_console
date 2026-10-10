defmodule FlezhaUi.Service.ConfigWatcherTest do
  @moduledoc """
  The dev console's config watcher, driven with file events as live reload's
  monitor sends them and a stop function that reports instead of stopping.
  """

  # The gating cases set application env, which every test would see.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias FlezhaUi.Service.ConfigWatcher

  @root "/flezha_ui"
  @settle_ms 50
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
            Process.sleep(:infinity)
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive :monitor_up
    {name, pid}
  end

  defp start_watcher({monitor, _pid} \\ start_monitor(self())) do
    test_pid = self()

    watcher =
      start_supervised!(
        {ConfigWatcher,
         monitor: monitor,
         files: @files,
         settle_ms: @settle_ms,
         stop: &send(test_pid, {:stopped, &1})}
      )

    assert_receive {:subscribed, ^watcher}
    watcher
  end

  defp write(watcher, path),
    do: send(watcher, {:file_event, self(), {Path.join(@root, path), [:modified, :closed]}})

  test "a config file written stops the VM once, non-zero" do
    watcher = start_watcher()
    write(watcher, "config/dev.exs")

    assert_receive {:stopped, 1}, 500
    refute_receive {:stopped, _}, 3 * @settle_ms
  end

  test "three writes of one save within the settle time stop once" do
    watcher = start_watcher()
    for _ <- 1..3, do: write(watcher, "config/config.exs")

    assert_receive {:stopped, 1}, 500
    refute_receive {:stopped, _}, 3 * @settle_ms
  end

  test "mix.exs and mix.lock count as configuration" do
    watcher = start_watcher()

    write(watcher, "mix.lock")
    assert_receive {:stopped, 1}, 500

    write(watcher, "mix.exs")
    assert_receive {:stopped, 1}, 500
  end

  test "a file that is not configuration stops nothing" do
    watcher = start_watcher()

    for path <-
          ~w(lib/flezha_ui/format.ex config/notes.txt assets/config/app.exs priv/mix.exs
             config/.#dev.exs config/flycheck_dev.exs config/dev.exs~ config/prod.exs),
        do: write(watcher, path)

    refute_receive {:stopped, _}, 3 * @settle_ms
  end

  test "a superseded settle timer is ignored" do
    watcher = start_watcher()
    send(watcher, {:settled, make_ref()})

    refute_receive {:stopped, _}, 3 * @settle_ms
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
    watcher = start_watcher(monitor)
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

  describe "the application" do
    @endpoint {:flezha_ui, FlezhaUiWeb.Endpoint}

    setup do
      flag = Application.get_env(:flezha_ui, :restart_on_config_change)
      endpoint = Application.get_env(:flezha_ui, FlezhaUiWeb.Endpoint)

      on_exit(fn ->
        Application.put_env(:flezha_ui, FlezhaUiWeb.Endpoint, endpoint)

        if flag == nil,
          do: Application.delete_env(:flezha_ui, :restart_on_config_change),
          else: Application.put_env(:flezha_ui, :restart_on_config_change, flag)
      end)
    end

    # What `mix phx.server` amounts to for `Phoenix.Endpoint.server?/2`.
    defp serving(server?) do
      {app, endpoint} = @endpoint
      conf = Application.get_env(app, endpoint)
      Application.put_env(app, endpoint, Keyword.put(conf, :server, server?))
    end

    test "starts no watcher while the flag is off" do
      serving(true)
      Application.put_env(:flezha_ui, :restart_on_config_change, false)

      assert FlezhaUi.Application.config_watcher_children() == []
      assert Process.whereis(ConfigWatcher) == nil
    end

    test "starts no watcher in a VM that does not serve the endpoint" do
      serving(false)
      Application.put_env(:flezha_ui, :restart_on_config_change, true)

      assert FlezhaUi.Application.config_watcher_children() == []
    end

    test "starts the watcher in the serving VM with the flag on" do
      serving(true)
      Application.put_env(:flezha_ui, :restart_on_config_change, true)

      assert FlezhaUi.Application.config_watcher_children() == [ConfigWatcher]
    end
  end
end
