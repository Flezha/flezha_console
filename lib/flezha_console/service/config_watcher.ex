if Code.ensure_loaded?(FileSystem) do
  defmodule FlezhaConsole.Service.ConfigWatcher do
    @moduledoc """
    Dev-only GenServer that stops the VM when a config or dependency file
    changes, because Phoenix's code reloader serves an error until a restart and
    the `fcon_web` container's restart policy is what starts the console again.

    It also marks when code the endpoint compiles changes, so the endpoint runs
    the reloader's whole-project check only then (`code_changed?/0`) rather
    than on every request. Without a watcher hearing the monitor, the endpoint
    checks every request, as Phoenix does.

    It listens to the file monitor `phoenix_live_reload` already runs over the
    project, as that library's own channel does, and starts nothing of its own.
    It watches the config files Phoenix's reloader checks, plus `mix.exs` and
    `mix.lock`, by exact path, so an editor's lock or temp file stops nothing.
    Editors write a file several times per save, so it stops once, 500 ms after
    the last matching write.
    """

    use GenServer, restart: :transient
    require Logger

    @monitor :phoenix_live_reload_file_monitor
    @settle_ms 500
    @code_changed {__MODULE__, :code_changed}

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      monitor = Keyword.get(opts, :monitor, @monitor)

      if pid = Process.whereis(monitor) do
        Process.monitor(pid)
        FileSystem.subscribe(monitor)

        # Set at first, so the first request after a boot checks.
        flag = :atomics.new(1, [])
        :atomics.put(flag, 1, 1)
        :persistent_term.put(@code_changed, flag)

        {:ok,
         %{
           files: MapSet.new(Keyword.get_lazy(opts, :files, &watched_files/0)),
           code_dirs: Keyword.get_lazy(opts, :code_dirs, &code_dirs/0),
           code_changed: flag,
           stop: Keyword.get(opts, :stop, &System.stop/1),
           settle_ms: Keyword.get(opts, :settle_ms, @settle_ms),
           pending: nil
         }}
      else
        unwatched("no live-reload file monitor")
        :ignore
      end
    end

    # What Phoenix's reloader refuses to serve past, `Mix.Project.config_files/0`,
    # without its `_build` lock, which a compile writes. Absolute, as events are.
    defp watched_files do
      config_dir = Path.absname("config") <> "/"
      configs = Enum.filter(Mix.Project.config_files(), &String.starts_with?(&1, config_dir))
      [Path.absname("mix.exs"), Path.absname("mix.lock") | configs]
    end

    # What Phoenix's reloader compiles: the project's code and its translations.
    defp code_dirs, do: [Path.absname("lib") <> "/", Path.absname("priv/gettext") <> "/"]

    @doc """
    Whether code the endpoint compiles may have changed since this was last
    asked; asking clears it. Always true while no watcher hears the monitor.
    """
    def code_changed? do
      case :persistent_term.get(@code_changed, nil) do
        nil -> true
        flag -> :atomics.exchange(flag, 1, 0) == 1
      end
    end

    @doc "Marks code changed again, for a reload that did not compile."
    def code_changed! do
      if flag = :persistent_term.get(@code_changed, nil), do: :atomics.put(flag, 1, 1)
      :ok
    end

    @impl true
    def handle_info({:file_event, _monitor, {path, _events}}, state) do
      if String.starts_with?(path, state.code_dirs), do: :atomics.put(state.code_changed, 1, 1)

      # Each write restarts the wait; only the latest timer's token is honoured.
      if MapSet.member?(state.files, path) do
        token = make_ref()
        Process.send_after(self(), {:settled, token}, state.settle_ms)
        {:noreply, %{state | pending: %{file: path, token: token}}}
      else
        {:noreply, state}
      end
    end

    def handle_info({:file_event, _monitor, :stop}, state) do
      unwatched("the live-reload file monitor stopped")
      {:stop, :normal, state}
    end

    def handle_info({:DOWN, _ref, :process, _monitor, _reason}, state) do
      unwatched("the live-reload file monitor exited")
      {:stop, :normal, state}
    end

    def handle_info({:settled, token}, %{pending: %{token: token, file: file}} = state) do
      Logger.warning(
        "[ConfigWatcher] #{Path.relative_to_cwd(file)} changed; stopping so the container restarts"
      )

      state.stop.(1)
      {:noreply, %{state | pending: nil}}
    end

    def handle_info({:settled, _superseded}, state), do: {:noreply, state}

    # Unheard changes would leave the endpoint serving stale code, so it goes
    # back to checking every request.
    defp unwatched(why) do
      :persistent_term.erase(@code_changed)
      Logger.warning("[ConfigWatcher] #{why}; a config change needs a manual restart")
    end
  end
end
