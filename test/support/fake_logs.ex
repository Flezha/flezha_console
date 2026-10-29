defmodule Flezha.Service.Logs do
  @moduledoc """
  Test-only stand-in for the published logs surface, compiled only under
  `MIX_ENV=test`. See `FakeController`.

  The tail holds the call open and hands records to the context's `:emit` pid,
  as core does, so `EventFeed` is driven through real `:erpc`. The read side is
  canned, so a test can produce what a live controller will not, such as the
  subsystem being switched off. The audit screen reads the `audit` kind.
  """

  use FakeController.Stub

  def tail(params, %{source: :ui} = ctx),
    do: FakeController.stream({__MODULE__, :tail}, [params, ctx], ctx)

  defstub files(params, %{source: :ui} = ctx), do: {:ok, %{files: [], unreachable: []}}

  defstub read(params, %{source: :ui} = ctx),
    do: {:ok, %{records: [], next: nil, unreachable: []}}

  defstub stats(params, %{source: :ui} = ctx),
    do: {:ok, %{controllers: [%{node: node()}], unreachable: []}}

  defstub rotate(params, %{source: :ui} = ctx), do: {:ok, %{rotated: [], unreachable: []}}
end
