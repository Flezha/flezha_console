defmodule FlezhaUi.Service.EventFeed do
  @moduledoc """
  Holds one published stream operation open and forwards what it hears.

  A stream operation — `Observability.tail/2`, `AuditLog.tail/2`,
  `Relay.listen/5` — runs in the `:erpc` worker on the controller and hands
  each event to the caller context's `:emit`. The feed passes its own pid as
  `:emit`, so every event arrives here as `{:flezha_emit, event}` and only data
  crosses the wire: nothing of this application runs on the controller.

  The controller watches the feed process and ends the stream when it exits, so
  stopping the feed is how a subscription is released. There is no second
  release path to forget.

  Where each event goes is the feed's destination:

    * `{:send, pid, tag}` sends `{:feed_event, tag, event}` to `pid`, and
      when the stream ends `{:feed_error, tag, error}` for an error or
      `{:feed_ended, tag, answer}` for the operation's own answer;
    * `{:broadcast, topic, fun}` broadcasts `fun.(event)` on `topic`, or
      nothing when `fun` answers `nil`.

  With `retry: true` an ended, refused or disconnected stream is opened again
  after the retry interval. Once a re-opened stream is known to be held — it
  delivered an event, or the settle interval passed without a refusal —
  `{:feed_reconnected, tag}` tells a `:send` destination its stream has a gap.
  Without it the feed stops once its stream has ended.
  """

  use GenServer
  require Logger

  alias FlezhaUi.Service.NodeManager

  @pubsub FlezhaUi.PubSub
  @topic "flezha:events"
  @default_retry_interval 10_000

  # A refusal is the operation's immediate answer; a re-opened stream that has
  # not answered within this long is being held.
  @default_settle_interval 1_000

  # The runner session signals core publishes on `:flezha_runner`. The source
  # carries the runner's other events too, which are not broadcast.
  @runner_signals [:runner_connected, :runner_disconnected]

  @type destination ::
          {:send, pid(), term()} | {:broadcast, String.t(), (term() -> term() | nil)}

  @doc """
  Starts a feed linked to the caller.

    * `:open` — a function taking the emit pid and opening the stream, as the
      `NodeManager` stream functions do (required);
    * `:to` — the destination (required);
    * `:retry` — re-open the stream when it ends (default `false`);
    * `:name` — a registered name.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The PubSub topic runner session events are broadcast on."
  def topic, do: @topic

  @doc """
  The supervised feed of runner session signals: a tail of `:flezha_runner`,
  held with the service token and re-opened whenever it ends, broadcasting
  `{:flezha_event, :runner_connected | :runner_disconnected, {namespace,
  runner}}` on `topic/0`.
  """
  def runners_child_spec do
    Supervisor.child_spec(
      {__MODULE__,
       name: __MODULE__.Runners,
       open: fn emit ->
         NodeManager.observability_tail(
           :flezha_runner,
           FlezhaUi.Accounts.service_flezha_token(),
           emit
         )
       end,
       to: {:broadcast, @topic, &runner_event/1},
       retry: true},
      id: __MODULE__.Runners
    )
  end

  @doc false
  def runner_event(%{name: name, metadata: metadata}) when name in @runner_signals,
    do: {:flezha_event, name, {Map.get(metadata, :namespace), Map.get(metadata, :runner)}}

  def runner_event(_signal), do: nil

  @doc """
  Stops a feed, releasing its stream. Safe on `nil` and on a feed already gone.

  Called by the owner of a `:send` feed with its `tag`, it also drops what the
  feed already sent under that tag, so a successor opened under the same tag
  never hears its predecessor.
  """
  def stop(feed, tag \\ nil) do
    if is_pid(feed), do: halt(feed)
    if tag != nil, do: flush(tag)
    :ok
  end

  defp halt(feed) do
    Process.unlink(feed)
    GenServer.stop(feed, :normal)
  catch
    :exit, _gone -> :ok
  end

  # Complete once `halt/1` returns: a local send is in the mailbox as soon as
  # it is made, and a stopped feed sends nothing more.
  defp flush(tag) do
    receive do
      {kind, ^tag, _payload} when kind in [:feed_event, :feed_error, :feed_ended] -> flush(tag)
      {:feed_reconnected, ^tag} -> flush(tag)
    after
      0 -> :ok
    end
  end

  @impl true
  def init(opts) do
    state = %{
      open: Keyword.fetch!(opts, :open),
      to: Keyword.fetch!(opts, :to),
      retry?: Keyword.get(opts, :retry, false),
      request: nil,
      retry_ref: nil,
      opened?: false,
      reopening?: false
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state), do: open(state)

  @impl true
  def handle_info(:retry_open, state), do: open(%{state | retry_ref: nil})

  def handle_info({:flezha_emit, event}, state) do
    state = settle(state)
    deliver(state.to, event)
    {:noreply, state}
  end

  def handle_info({:settled, request_id}, %{request: %{id: request_id}} = state),
    do: {:noreply, settle(state)}

  def handle_info({:nodedown, node}, %{request: %{node: node}} = state) do
    Logger.warning("[EventFeed] Controller node #{node} went down")
    ended(%{state | request: nil}, {:error, :node_not_connected})
  end

  def handle_info(message, %{request: %{node: node} = request} = state) do
    case NodeManager.stream_result(message, request) do
      :no_response ->
        {:noreply, state}

      {:ended, result} ->
        Node.monitor(node, false)
        ended(%{state | request: nil}, result)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp open(state) do
    case state.open.(self()) do
      {:ok, %{node: node, id: request_id} = request} ->
        Node.monitor(node, true)

        if state.opened?,
          do: Process.send_after(self(), {:settled, request_id}, settle_interval())

        {:noreply, %{state | request: request, opened?: true, reopening?: state.opened?}}

      {:error, _reason} = refused ->
        ended(state, refused)
    end
  end

  defp settle(%{reopening?: true} = state) do
    notify(state.to, :feed_reconnected)
    %{state | reopening?: false}
  end

  defp settle(state), do: state

  # The stream answered, so it is over: a window ran out, the relay ended, the
  # writer closed, or the controller refused it.
  defp ended(state, result) do
    state = %{state | reopening?: false}
    report(state.to, result)
    if state.retry?, do: {:noreply, schedule_retry(state)}, else: {:stop, :normal, state}
  end

  # A dropped connection delivers both the stream's answer and a `:nodedown`.
  # Without this guard each would schedule its own retry, and the second would
  # open a stream only to hold two.
  defp schedule_retry(%{retry_ref: ref} = state) when is_reference(ref), do: state

  defp schedule_retry(state) do
    %{state | retry_ref: Process.send_after(self(), :retry_open, retry_interval())}
  end

  defp deliver({:send, pid, tag}, event), do: send(pid, {:feed_event, tag, event})

  defp deliver({:broadcast, topic, fun}, event) do
    case fun.(event) do
      nil -> :ok
      message -> Phoenix.PubSub.broadcast(@pubsub, topic, message)
    end
  end

  defp report({:send, pid, tag}, {:error, reason}), do: send(pid, {:feed_error, tag, reason})
  defp report({:send, pid, tag}, answer), do: send(pid, {:feed_ended, tag, answer})

  defp report({:broadcast, topic, _fun}, {:error, reason}) do
    Logger.warning("[EventFeed] Stream for #{topic} unavailable: #{inspect(reason)}")
  end

  defp report({:broadcast, topic, _fun}, answer) do
    Logger.debug("[EventFeed] Stream for #{topic} ended: #{inspect(answer)}")
  end

  defp notify({:send, pid, tag}, message), do: send(pid, {message, tag})
  defp notify(_broadcast, _message), do: :ok

  defp retry_interval do
    Application.get_env(:flezha_ui, :event_feed_retry_interval_ms, @default_retry_interval)
  end

  defp settle_interval do
    Application.get_env(:flezha_ui, :event_feed_settle_interval_ms, @default_settle_interval)
  end
end
