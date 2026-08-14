defmodule Flezha.Service.AuditLog do
  @moduledoc """
  Test-only stand-in for the controller's audit service, compiled only under
  `MIX_ENV=test`.

  It carries the real module's name on purpose: `FlezhaUi.Service.EventRelay`
  calls `Flezha.Service.AuditLog` by name, and shipping this alongside the
  relay onto a peer node is what lets the real relay's audit-tail subscription
  be tested end to end.

  Tracks subscribers in an agent-free ETS table so a test can assert that the
  relay — not a throwaway `:erpc` process — holds the subscription, and that it
  is released when the relay unwinds.
  """

  @table :fake_audit_log_tails

  @doc """
  Registers the calling process as a tail subscriber, as the real one does.

  A `:refuse` key in `params` makes it answer the way a controller with the
  subsystem switched off does, so the relay's failure path is reachable.
  """
  def tail(params, %{source: :ui}) do
    ensure_table()

    if Map.has_key?(params, :refuse) do
      {:error, :audit_log_disabled}
    else
      ref = make_ref()
      :ets.insert(@table, {ref, self()})
      {:ok, ref}
    end
  end

  def unsubscribe(ref, %{source: :ui}) when is_reference(ref) do
    ensure_table()
    :ets.delete(@table, ref)
    :ok
  end

  @doc "Pids currently subscribed to the tail."
  def tails do
    ensure_table()
    :ets.tab2list(@table) |> Enum.map(fn {_ref, pid} -> pid end)
  end

  # The table is owned by whichever process touches it first; for a stand-in
  # living only as long as the peer node, that is good enough.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
