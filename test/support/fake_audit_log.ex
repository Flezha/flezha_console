defmodule Flezha.Service.AuditLog do
  @moduledoc """
  Test-only stand-in for the controller's audit service, compiled only under
  `MIX_ENV=test`.

  It carries the real module's name on purpose: `FlezhaUi.Service.EventRelay`
  calls `Flezha.Service.AuditLog` by name, and shipping this alongside the
  relay onto a peer node is what lets the real relay's audit-tail subscription
  be tested end to end.

  Both halves keep their state in `FakeController.store/0`: the tail side
  records which pid holds each subscription, so a test can assert the relay —
  not a throwaway `:erpc` process — holds it and releases it when it unwinds;
  the read side is canned, so a test can produce what a live controller will
  not, such as the subsystem being switched off.
  """

  use FakeController.Stub

  @doc """
  Registers the calling process as a tail subscriber, as the real one does.

  A `:refuse` key in `params` makes it answer the way a controller with the
  subsystem switched off does, so the relay's failure path is reachable.
  """
  def tail(params, %{source: :ui}) do
    if Map.has_key?(params, :refuse) do
      {:error, :audit_log_disabled}
    else
      ref = make_ref()
      :ets.insert(FakeController.store(), {{:tail, ref}, self()})

      # A relay killed outright runs no `after` block, so the registry — not the
      # subscriber — is what has to notice it is gone.
      FakeController.watch(self())

      {:ok, ref}
    end
  end

  def unsubscribe(ref, %{source: :ui}) when is_reference(ref) do
    :ets.delete(FakeController.store(), {:tail, ref})
    :ok
  end

  @doc "Pids currently subscribed to the tail."
  def tails do
    FakeController.store()
    |> :ets.match({{:tail, :_}, :"$1"})
    |> List.flatten()
  end

  # The read side the audit screen calls. The context pattern is kept strict:
  # the UI is expected to identify itself as `:ui` on every audited read. The
  # catalog read binds it too, so a test can assert which principal it named.
  defstub list_files(%{source: :ui} = ctx), do: {:ok, []}
  defstub read(params, %{source: :ui}), do: {:ok, []}
  defstub stats(%{source: :ui}), do: {:ok, %{}}
end
