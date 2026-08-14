defmodule FlezhaUi.Service.EventBridge do
  @moduledoc """
  Relays flezha controller events onto Phoenix PubSub topic `"flezha:events"`.

  The controller's event bus registers the *calling* process
  (`EventManager.add_handler/1` is `pg:join(scope, event, self())`, and `pg`
  refuses a non-local pid). Under `:erpc` that caller is a throwaway process on
  the controller which dies the instant the call returns, so the subscription
  could never hold. Instead this bridge runs `FlezhaUi.Service.EventRelay`
  **on the controller node**: the relay subscribes as itself and forwards each
  event back here, which republishes it locally.

  The relay's *source* is shipped to the controller and compiled there before
  it is spawned, because the controller carries no `FlezhaUi.*` code of its
  own. Source rather than a compiled beam: the UI and the controller need not
  run the same Erlang/OTP release, and today they do not — a beam built on
  OTP 28 fails to load on OTP 27 with `corrupt atom table`. Compiling on the
  controller uses the controller's own compiler, so the two stay independent
  and this UI can move to a newer Elixir without dragging the controller.

  Recompiling on every (re)connect also means a redeployed UI never leaves a
  stale relay version running there.
  """

  use GenServer
  require Logger

  alias FlezhaUi.Service.EventRelay
  alias FlezhaUi.Service.NodeManager

  @pubsub FlezhaUi.PubSub
  @topic "flezha:events"
  @default_retry_interval 10_000
  @compile_timeout 15_000

  # Read at compile time, because the relay must not read its own source: on the
  # controller there is no file behind the module. Held here rather than there
  # for the same reason.
  @relay_path Path.join(__DIR__, "event_relay.ex")
  @external_resource @relay_path
  @relay_source File.read!(@relay_path)

  @events [:runner_connected_event, :runner_disconnected_event]

  # Controller event name -> the tag LiveViews subscribe on.
  @event_tags %{
    runner_connected_event: :runner_connected,
    runner_disconnected_event: :runner_disconnected
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def topic, do: @topic

  @doc "The controller events this bridge relays."
  def events, do: @events

  @doc "The relay's module name and source, as shipped to the controller."
  def relay_source, do: {EventRelay, @relay_source}

  @doc """
  Compiles `source` on `node` and spawns `module.start(owner, args...)` there.

  Answers `{:ok, pid}` for the remote process, or `{:error, reason}` when the
  node is unreachable or the source would not compile. The spawned process is
  linked, so the caller learns about its death.

  Exposed for reuse by any screen needing a controller subscription whose API
  registers the caller rather than an explicit pid.
  """
  def start_relay(node, {module, source}, owner, args) when is_atom(node) and is_pid(owner) do
    with {:ok, ^module} <- compile_remote(node, module, source) do
      {:ok, Node.spawn_link(node, module, :start, [owner | args])}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Stops a relay started by `start_relay/4`.

  Unlinks before killing: without that the caller gets an `EXIT` for a relay it
  retired on purpose, and reads it as a failure to recover from.
  """
  def stop_relay(relay) when is_pid(relay) do
    Process.unlink(relay)
    Process.exit(relay, :shutdown)
    :ok
  end

  def stop_relay(_relay), do: :ok

  defp compile_remote(node, module, source) do
    # `Code.compile_string/1` both compiles and loads on the node it runs on,
    # so the resulting module is built by that node's own compiler.
    #
    # Bounded deliberately: `:erpc.call/4` waits forever, which would wedge the
    # bridge against a controller that has stopped answering — and the bridge
    # blocked here cannot even be shut down.
    case :erpc.call(node, Code, :compile_string, [source], @compile_timeout) do
      compiled when is_list(compiled) ->
        if Enum.any?(compiled, fn {mod, _binary} -> mod == module end) do
          {:ok, module}
        else
          {:error, {:relay_module_not_defined, module}}
        end

      other ->
        {:error, {:relay_compile_failed, other}}
    end
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{relay: nil, node: nil, retry_ref: nil}, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    {:noreply, attempt_subscribe(state)}
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    {:noreply, attempt_subscribe(%{state | retry_ref: nil})}
  end

  # Forwarded by the relay running on the controller.
  @impl true
  def handle_info({:relay_event, :controller_events, {event, data}}, state)
      when is_map_key(@event_tags, event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:flezha_event, @event_tags[event], data})
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{relay: pid} = state) do
    Logger.warning("[EventBridge] Relay exited: #{inspect(reason)}, re-establishing")
    {:noreply, schedule_retry(%{state | relay: nil})}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_info({:nodedown, node}, %{node: node} = state) do
    Logger.warning("[EventBridge] Controller node #{node} went down")
    {:noreply, schedule_retry(teardown(state))}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[EventBridge] Unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    teardown(state)
    :ok
  end

  defp attempt_subscribe(state) do
    # Reap any prior relay first: two relays would each register a handler and
    # every event would then arrive twice.
    state = teardown(state)

    case NodeManager.connected_node() do
      nil ->
        schedule_retry(state)

      node ->
        case start_relay(node, relay_source(), self(), [{:events, @events}, :controller_events]) do
          {:ok, relay} ->
            Node.monitor(node, true)
            Logger.info("[EventBridge] Relay established on #{node}")
            %{state | relay: relay, node: node}

          {:error, reason} ->
            Logger.warning(
              "[EventBridge] Could not establish relay: #{inspect(reason)}, " <>
                "retrying in #{retry_interval()}ms"
            )

            schedule_retry(state)
        end
    end
  end

  # The relay removes its own handlers as it unwinds.
  defp teardown(%{relay: relay} = state) do
    stop_relay(relay)
    %{state | relay: nil}
  end

  # A dropped connection produces both a relay EXIT and a `:nodedown`. Without
  # this guard each would schedule its own retry, and the second attempt would
  # spawn a remote relay only to tear down the one the first just made.
  defp schedule_retry(%{retry_ref: ref} = state) when is_reference(ref), do: state

  defp schedule_retry(state) do
    %{state | retry_ref: Process.send_after(self(), :retry_subscribe, retry_interval())}
  end

  defp retry_interval do
    Application.get_env(:flezha_ui, :event_bridge_retry_interval_ms, @default_retry_interval)
  end
end
