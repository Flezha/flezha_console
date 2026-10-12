defmodule FlezhaUiWeb.Live.RunnerActions do
  @moduledoc """
  Dropping and readmitting a runner, for every screen with a runner table.

      use FlezhaUiWeb.Live.Refresh, every: 5_000
      use FlezhaUiWeb.Live.RunnerActions

      def mount(_params, _session, socket) do
        {:ok, socket |> start_refresh() |> runner_actions_init() |> refresh()}
      end

  The host renders `FlezhaUiWeb.Runners.runner_table/1` per namespace and
  `runner_dialogs/1` once, and loads each namespace's marks in its own refresh;
  the events are injected. A completed drop or readmit says so and reloads the
  screen, so the runner leaves the list and its mark appears without waiting
  for the tick.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias FlezhaUi.Service.NodeManager

  # Named exactly, so a host's own events cannot be swallowed.
  @events ~w(drop_runner cancel_drop_runner confirm_drop_runner
             readmit_runner cancel_readmit_runner confirm_readmit_runner)

  @doc false
  defmacro __using__(_opts) do
    events = @events

    quote do
      import FlezhaUiWeb.Live.RunnerActions, only: [runner_actions_init: 1]
      import FlezhaUiWeb.Runners, only: [runner_table: 1, runner_dialogs: 1]

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) when event in unquote(events) do
        {:noreply, FlezhaUiWeb.Live.RunnerActions.handle_event(__MODULE__, event, params, socket)}
      end
    end
  end

  @doc "Initial assigns for a host. Call before the first load."
  def runner_actions_init(socket),
    do: assign(socket, runner_drop: nil, runner_readmit: nil, runner_error: nil)

  @doc """
  The refusal to show on `namespace`'s table, from the host's `@runner_error`,
  if the last action there was refused.
  """
  def error_for({namespace, reason}, namespace), do: reason
  def error_for(_runner_error, _namespace), do: nil

  @doc false
  def handle_event(_module, "drop_runner", %{"namespace" => ns, "runner" => id} = params, socket),
    do: assign(socket, runner_drop: %{namespace: ns, runner: id, pid: params["pid"]})

  def handle_event(_module, "cancel_drop_runner", _params, socket),
    do: assign(socket, runner_drop: nil)

  def handle_event(module, "confirm_drop_runner", %{"namespace" => ns, "runner" => id}, socket) do
    ns
    |> NodeManager.drop_runner(id, socket.assigns.flezha_token)
    |> settle(module, ns, "Runner #{id} dropped from #{ns}.", assign(socket, runner_drop: nil))
  end

  def handle_event(_module, "readmit_runner", %{"namespace" => ns, "stable_id" => id}, socket),
    do: assign(socket, runner_readmit: %{namespace: ns, stable_id: id})

  def handle_event(_module, "cancel_readmit_runner", _params, socket),
    do: assign(socket, runner_readmit: nil)

  def handle_event(
        module,
        "confirm_readmit_runner",
        %{"namespace" => ns, "stable_id" => id},
        socket
      ) do
    ns
    |> NodeManager.readmit_runner(id, socket.assigns.flezha_token)
    |> settle(
      module,
      ns,
      "#{id} may connect to #{ns} again.",
      assign(socket, runner_readmit: nil)
    )
  end

  defp settle({:error, reason}, _module, ns, _done, socket),
    do: assign(socket, runner_error: {ns, reason})

  defp settle(_ok, module, _ns, done, socket) do
    module
    |> FlezhaUiWeb.Live.Refresh.tick(assign(socket, runner_error: nil))
    |> put_flash(:info, done)
  end
end
