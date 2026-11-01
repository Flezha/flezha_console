defmodule FlezhaConsole.Service.EventFeed do
  @moduledoc """
  Holds one published stream operation open and forwards what it hears.

  A stream operation — `Observability.tail/2`, `Logs.tail/2`,
  `Relay.listen/5` — is held open on the controller's stream route by a
  process `NodeManager` links to the feed, which hands each server-sent event
  here as `{:flezha_emit, event}`, decoded into the term a screen matches.

  When the feed exits its stream's request is closed and the controller ends
  the operation, so stopping the feed is how a subscription is released. There
  is no second release path to forget.

  Where each event goes is the feed's destination:

    * `{:send, pid, tag}` sends `{:feed_event, tag, event}` to `pid`, and
      when the stream ends `{:feed_error, tag, error}` for an error or
      `{:feed_ended, tag, answer}` for the operation's own answer;
    * `{:broadcast, topic, fun}` broadcasts `fun.(event)` on `topic`, or
      nothing when `fun` answers `nil`.

  With `retry: true` an ended, refused or disconnected stream is opened again
  after the retry interval. Without it the feed stops once its stream has
  ended, unless the controller ended it with `overrun` because the console fell
  behind: that stream is always opened again. Once a re-opened stream is known
  to be held — it delivered an event, or the settle interval passed without a
  refusal — `{:feed_reconnected, tag}` tells a `:send` destination its stream
  has a gap.

  A broadcast feed has no owner to tell, so it keeps its last refusal and
  answers it from `error/1`. With `announce: true` it also broadcasts
  `{:flezha_feed, name, error}` on its topic when it is refused and again, with
  `nil`, once a re-opened stream is held.
  """

  use GenServer
  require Logger

  alias FlezhaConsole.Service.NodeManager

  @pubsub FlezhaConsole.PubSub
  @default_retry_interval 10_000

  # A refusal is the operation's immediate answer; a re-opened stream that has
  # not answered within this long is being held.
  @default_settle_interval 1_000

  # The runner session signals core publishes on `:flezha_runner`, and the
  # relay lifecycle signals on `:flezha_relay`. Each source carries other
  # events too, which are not broadcast: a dropped runner's refused retries
  # among them, which arrive at the runner's reconnect rate and change nothing
  # a screen shows.
  @runner_signals [:runner_connected, :runner_disconnected, :runner_dropped, :runner_readmitted]
  @relay_signals [:relay_started, :relay_stopped, :relay_exited]

  # One topic per source, so a screen hears only the signals it handles: every
  # refreshing screen subscribes to runner sessions, the relays index alone to
  # relay lifecycle signals and that feed's refusals.
  @signal_topics %{flezha_runner: "flezha:events", flezha_relay: "flezha:relays"}
  @signal_sources Map.keys(@signal_topics)

  @type destination ::
          {:send, pid(), term()} | {:broadcast, String.t(), (term() -> term() | nil)}

  @doc """
  Starts a feed linked to the caller.

    * `:open` — a function taking the emit pid and opening the stream, as the
      `NodeManager` stream functions do (required);
    * `:to` — the destination (required);
    * `:retry` — re-open the stream when it ends (default `false`);
    * `:announce` — broadcast the feed's refusals on its topic (default `false`);
    * `:name` — a registered name.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    GenServer.start_link(
      __MODULE__,
      Keyword.put(opts, :name, name),
      if(name, do: [name: name], else: [])
    )
  end

  @doc """
  A feed linked to the caller, holding a listen on `relay_id`'s `direction`
  (`NodeManager.listen/5`) and sending to the caller under `tag`: leaving
  the screen that started it ends the listen on the controller.
  """
  def listen(namespace, relay_id, direction, token, tag) do
    {:ok, feed} =
      start_link(
        open: &NodeManager.listen(namespace, relay_id, direction, token, &1),
        to: {:send, self(), tag}
      )

    feed
  end

  @doc "The PubSub topic runner session events are broadcast on."
  def topic, do: topic(:flezha_runner)

  @doc "The PubSub topic the signals of `source` are broadcast on."
  def topic(source), do: Map.fetch!(@signal_topics, source)

  @doc """
  The supervised signal feeds, one tail per source, each held with the service
  token and re-opened whenever it ends, broadcasting on `topic/1` of its source:

    * `:flezha_runner` — `{:flezha_event, :runner_connected |
      :runner_disconnected | :runner_dropped | :runner_readmitted,
      {namespace, runner}}`, a drop or readmit naming the runner by its stable
      id;
    * `:flezha_relay` — `{:flezha_event, :relay_started | :relay_stopped |
      :relay_exited, {namespace, entry}}`, the entry as `signal_event/2` maps it,
      and its own refusals, which the relays index states.
  """
  def signal_child_specs do
    for source <- @signal_sources do
      Supervisor.child_spec(
        {__MODULE__,
         name: signal_feed(source),
         open: fn emit ->
           NodeManager.observability_tail(
             source,
             FlezhaConsole.Accounts.service_flezha_token(),
             emit
           )
         end,
         to: {:broadcast, topic(source), &signal_event(source, &1)},
         retry: true,
         announce: source == :flezha_relay},
        id: signal_feed(source)
      )
    end
  end

  @doc "The registered name of the supervised feed of `source`."
  def signal_feed(source) when source in @signal_sources, do: Module.concat(__MODULE__, source)

  @doc """
  The event a signal is broadcast as, or `nil` for one that is not.

  The three relay signals name their relay differently — `relay_exited` says
  `relay_id` — and each is read as it is, into one entry: `event`, `namespace`,
  `relay`, `factory`, `runner`, `reason` and `at`, the time it arrived here.
  """
  def signal_event(:flezha_runner, %{name: name, metadata: metadata})
      when name in @runner_signals,
      do:
        {:flezha_event, name,
         {Map.get(metadata, :namespace),
          Map.get(metadata, :runner) || Map.get(metadata, :stable_id)}}

  def signal_event(:flezha_relay, %{name: name, metadata: metadata})
      when name in @relay_signals do
    namespace = Map.get(metadata, :namespace)

    entry = %{
      event: name,
      namespace: namespace,
      relay: Map.get(metadata, :relay) || Map.get(metadata, :relay_id),
      factory: Map.get(metadata, :factory),
      runner: Map.get(metadata, :runner_id),
      reason: Map.get(metadata, :reason),
      at: DateTime.utc_now()
    }

    {:flezha_event, name, {namespace, entry}}
  end

  def signal_event(_source, _signal), do: nil

  @doc """
  Why the feed `name` is not holding its stream, or `nil` when it is — or when
  no such feed runs, which leaves a screen to say nothing rather than guess.
  """
  def error(name) do
    # Short, because a feed opening its stream answers no call until it has,
    # and a screen asking at mount must not wait out a slow controller.
    GenServer.call(name, :error, 200)
  catch
    :exit, _not_running -> nil
  end

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
      name: Keyword.get(opts, :name),
      open: Keyword.fetch!(opts, :open),
      to: Keyword.fetch!(opts, :to),
      retry?: Keyword.get(opts, :retry, false),
      announce?: Keyword.get(opts, :announce, false),
      request: nil,
      retry_ref: nil,
      opened?: false,
      reopening?: false,
      error: nil
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state), do: open(state)

  @impl true
  def handle_call(:error, _from, state), do: {:reply, state.error, state}

  @impl true
  def handle_info(:retry_open, state), do: open(%{state | retry_ref: nil})

  def handle_info({:flezha_emit, event}, state) do
    state = settle(state)
    deliver(state.to, event)
    {:noreply, state}
  end

  def handle_info({:settled, request_id}, %{request: %{id: request_id}} = state),
    do: {:noreply, settle(state)}

  def handle_info(message, %{request: %{} = request} = state) do
    case NodeManager.stream_result(message, request) do
      :no_response -> {:noreply, state}
      {:ended, result} -> ended(%{state | request: nil}, result)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp open(state) do
    case state.open.(self()) do
      {:ok, %{id: request_id} = request} ->
        # A stream opened after one that ended, or after a refusal, is announced
        # once it is held, so whoever heard the refusal hears it cleared.
        reopening? = state.opened? or state.error != nil

        if reopening?,
          do: Process.send_after(self(), {:settled, request_id}, settle_interval())

        {:noreply, %{state | request: request, opened?: true, reopening?: reopening?}}

      {:error, _reason} = refused ->
        ended(state, refused)
    end
  end

  defp settle(%{reopening?: true} = state) do
    notify(state.to, :feed_reconnected)
    if state.error != nil, do: announce(state, nil)
    %{state | reopening?: false, error: nil}
  end

  defp settle(state), do: state

  # The stream answered, so it is over: a window ran out, the relay ended, the
  # writer closed, or the controller refused it.
  #
  # `overrun` is no answer: the controller cut a stream the console fell behind
  # on, so it is opened again, and the gap is told once it is held.
  defp ended(state, {:error, :overrun}) do
    Logger.info("[EventFeed] The controller cut a stream this console fell behind on")
    {:noreply, schedule_retry(%{state | reopening?: false})}
  end

  defp ended(state, result) do
    state = %{state | reopening?: false, error: refusal(result)}
    report(state.to, result)
    if state.error != nil, do: announce(state, state.error)
    if state.retry?, do: {:noreply, schedule_retry(state)}, else: {:stop, :normal, state}
  end

  # A refusal and a retry already waiting must not each schedule a retry, which
  # would open a stream only to hold two.
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

  defp refusal({:error, reason}), do: reason
  defp refusal(_answer), do: nil

  defp announce(%{announce?: true, to: {:broadcast, topic, _fun}, name: name}, error),
    do: Phoenix.PubSub.broadcast(@pubsub, topic, {:flezha_feed, name, error})

  defp announce(_state, _error), do: :ok

  defp retry_interval do
    Application.get_env(:flezha_console, :event_feed_retry_interval_ms, @default_retry_interval)
  end

  defp settle_interval do
    Application.get_env(:flezha_console, :event_feed_settle_interval_ms, @default_settle_interval)
  end
end
