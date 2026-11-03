defmodule FlezhaConsoleWeb.FactoryLive do
  @moduledoc """
  The factories the runners announce, and one factory's page.

  The listing (`:index`) serves `/factories` for every namespace the token
  reaches and `/namespaces/:ns/factories` for one. It reads the factory
  catalog once per namespace, the read every screen naming a factory makes,
  so it costs no call per factory.

  The page (`:show`) at `/namespaces/:ns/factories/:id` explains one factory,
  running or not: how it runs and what a failed run undoes, what it
  declares, its graph drawn still, its entry API and its last runs. Its
  factory is read when the page opens and again when a runner of its
  namespace comes or goes, since that is when an announcement changes; its
  last runs are read on every refresh. Both reads run off the LiveView
  process.
  """

  use FlezhaConsoleWeb, :live_view

  use FlezhaConsoleWeb.Live.Refresh,
    every: 5_000,
    background: true,
    on_events: [:runner_connected, :runner_disconnected]

  use FlezhaConsoleWeb.Topology

  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.Live.Target
  alias FlezhaConsoleWeb.LogLines
  alias FlezhaConsoleWeb.RelayLive
  alias FlezhaConsoleWeb.Topology

  @runs_shown 10

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> Topology.init()
     |> assign(
       loaded?: false,
       load_error: nil,
       groups: [],
       unreachable: [],
       factory: nil,
       factory_error: nil,
       factory_for: :unread,
       runs: [],
       runs_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    ns = params["ns"]
    id = params["id"]

    title =
      case socket.assigns.live_action do
        :show -> id
        :index -> Layouts.scoped_title("Factories", ns)
      end

    {:noreply,
     socket
     |> assign(ns: ns, factory_id: id, page_title: title)
     |> refresh_when_connected()}
  end

  # ---- Reads ----

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_read(%{assigns: %{live_action: :index}} = socket) do
    %{ns: ns, flezha_token: token} = socket.assigns

    fn ->
      {namespaces, error} = NodeManager.namespaces_in_scope(ns, token)

      %{
        error: error,
        catalogs:
          for(
            name <- namespaces,
            do: {name, NodeManager.factory_catalog(name, token)}
          )
      }
    end
  end

  def refresh_read(socket) do
    %{ns: ns, factory_id: id, flezha_token: token} = socket.assigns
    epoch = socket.assigns[:runner_epoch]
    read? = socket.assigns.factory_for != epoch or socket.assigns.factory_error != nil

    fn ->
      %{
        epoch: epoch,
        factory: if(read?, do: NodeManager.factory(ns, id, token), else: :kept),
        runs: NodeManager.ended_runs(ns, %{"factory" => id}, %{limit: @runs_shown}, token)
      }
    end
  end

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh_apply(socket, {:exit, reason}),
    do: assign(socket, load_error: {:remote_error, reason}, loaded?: true)

  def refresh_apply(%{assigns: %{live_action: :index}} = socket, {:ok, read}) do
    groups =
      for {namespace, answer} <- read.catalogs do
        {rows, error} = NodeManager.ok_or_error(answer, [])
        %{namespace: namespace, rows: rows, error: error}
      end

    assign(socket,
      loaded?: true,
      load_error: read.error,
      groups: groups,
      unreachable: NodeManager.unreachable(Enum.map(read.catalogs, &elem(&1, 1)))
    )
  end

  def refresh_apply(socket, {:ok, read}) do
    socket = assign_factory(socket, read.factory, read.epoch)

    socket
    |> assign(loaded?: true, load_error: nil)
    |> assign_runs(read.runs)
    |> assign(unreachable: NodeManager.unreachable([{:ok, socket.assigns.factory}, read.runs]))
  end

  defp assign_runs(socket, {:ok, %{records: records}}),
    do: assign(socket, runs: Enum.take(records, @runs_shown), runs_error: nil)

  defp assign_runs(socket, {:error, reason}), do: assign(socket, runs: [], runs_error: reason)

  defp assign_factory(socket, :kept, _epoch), do: socket

  defp assign_factory(socket, {:ok, factory}, epoch) do
    socket
    |> assign(factory: factory, factory_error: nil, factory_for: epoch)
    |> Topology.load_still(factory)
  end

  defp assign_factory(socket, {:error, reason}, epoch),
    do: assign(socket, factory: nil, factory_error: reason, factory_for: epoch)

  # ---- Words ----

  @doc """
  How a factory runs, as `[{glossary term, lead, words}]` read in order: its
  run, then for a steps factory what one pass is (`each`) after a colon and
  what a failed run undoes (`on_failure`) as a sentence of its own. What the
  factory does not announce is left out.
  """
  def run_parts(factory) do
    steps? = to_string(factory.run) == "steps"

    [
      {"run", "", factory.run && Words.sentence_start(Words.text(:run_shape, factory.run))},
      {"each", ": ", steps? && factory.each && Words.text(:each, factory.each)},
      {"on_failure", ". ",
       steps? && factory.on_failure &&
         Words.sentence_start(Words.text(:on_failure, factory.on_failure))}
    ]
    |> Enum.filter(fn {_term, _lead, words} -> is_binary(words) end)
  end

  @doc """
  Whether a steps factory can undo a failed run, from its graph's
  `compensates`: `{:some, tasklets}`, `:none`, or `:not_reported` when no
  tasklet says. `nil` for a flow factory, which undoes nothing.
  """
  def compensates(%{run: run} = factory) do
    if to_string(run) == "steps", do: compensating(factory[:graph])
  end

  defp compensating(%{tasklets: tasklets}) do
    case Enum.reject(tasklets, &is_nil(&1[:compensates])) do
      [] -> :not_reported
      reported -> some(for(%{compensates: true, name: name} <- reported, do: name))
    end
  end

  defp compensating(_no_graph), do: :not_reported

  defp some([]), do: :none
  defp some(names), do: {:some, names}

  @doc "The entry API as the shared API rendering takes it: this factory's one entry."
  def api_of(factory) do
    [
      %{
        factory: factory.id,
        description: nil,
        channels: factory[:api] || [],
        disagree: factory[:api_disagree] == true
      }
    ]
  end

  @doc "How a factory runs, in a few words for a listing: its run and what one pass is."
  def run_summary(%{run: nil}), do: "—"

  def run_summary(factory) do
    case run_parts(factory) do
      [_run, {"each", _lead, pass} | _failure] -> "#{Words.text(:run, factory.run)}: #{pass}"
      _run -> Words.text(:run, factory.run)
    end
  end

  # ---- Rendering ----

  attr :factory, :map, required: true

  # Whether a failed run of a steps factory can be undone, and by which
  # tasklets; the dangerous case, undo_all with nothing to undo, is a warning.
  defp compensation(assigns) do
    assigns = assign(assigns, :said, compensates(assigns.factory))

    ~H"""
    <p :if={match?({:some, _}, @said)} data-testid="factory-compensation">
      It supports <.term key="compensation" id="factory-term-compensation" />: {undoers(@said)}.
    </p>
    <p :if={@said == :none} data-testid="factory-compensation">
      No tasklet of it declares a <.term key="compensation" id="factory-term-compensation" />.
    </p>
    <.notice
      :if={@said == :none and to_string(@factory.on_failure) == "undo_all"}
      kind={:error}
      testid="factory-undo-warning"
    >
      A failed run cannot undo the work of its completed steps: it is set to undo every finished step, but no step can be undone.
    </.notice>
    <p :if={@said == :not_reported} data-testid="factory-compensation">
      Its runners do not report <.term key="compensation" id="factory-term-compensation" />.
    </p>
    """
  end

  defp undoers({:some, [one]}), do: "#{one} undoes its work when its run fails or is stopped"

  defp undoers({:some, names}),
    do: "#{Words.join(names)} undo their work when their run fails or is stopped"
end
