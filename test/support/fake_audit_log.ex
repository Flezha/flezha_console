defmodule Flezha.Service.AuditLog do
  @moduledoc """
  Test-only stand-in for the published audit surface, compiled only under
  `MIX_ENV=test`. See `FakeController`.

  The tail holds the call open and hands records to the context's `:emit` pid,
  as core does, so `EventFeed` is driven through real `:erpc`. The read side is
  canned, so a test can produce what a live controller will not, such as the
  subsystem being switched off.
  """

  use FakeController.Stub

  def tail(params, %{source: :ui} = ctx),
    do: FakeController.stream({__MODULE__, :tail}, [params, ctx], ctx)

  defstub list_files(%{source: :ui} = ctx), do: {:ok, []}
  defstub read(params, %{source: :ui} = ctx), do: {:ok, []}
  defstub stats(%{source: :ui} = ctx), do: {:ok, %{}}
end
