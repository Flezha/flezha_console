defmodule Flezha.Service.EventManager do
  @moduledoc """
  Test-only stand-in for the controller's event manager, compiled only under
  `MIX_ENV=test`.

  It carries the real module's name on purpose: `FlezhaUi.Service.EventRelay`
  calls `Flezha.Service.EventManager` by name, and shipping this alongside the
  relay onto a peer node is what lets the *real* relay be tested end to end
  rather than a lookalike.

  Records handler registrations in the process dictionary of whichever process
  calls it, so a test can assert the relay subscribed as itself.
  """

  def add_handler(event) do
    Process.put(:handlers, [event | handlers()])
    :ok
  end

  def rem_handler(event) do
    Process.put(:handlers, List.delete(handlers(), event))
    :ok
  end

  @doc "Events the calling process is currently registered for."
  def handlers, do: Process.get(:handlers, [])
end
