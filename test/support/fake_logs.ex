defmodule Flezha.Service.Logs do
  @moduledoc """
  Test-only stand-in for the published logs surface, compiled only under
  `MIX_ENV=test`. See `FakeController`.

  The tail holds the call open and hands records to the context's `:emit` pid,
  as core does, so `EventFeed` is driven through real `:erpc`. The read side is
  canned, so a test can produce what a live controller will not, such as a
  kind being switched off. It declares the `audit` and `relay_history` kinds;
  a test answering per kind sets `{:per_arg, {0, :kind}, by_kind, default}`.
  """

  use FakeController.Stub

  def tail(params, %{source: :ui} = ctx),
    do: FakeController.stream({__MODULE__, :tail}, [params, ctx], ctx)

  defstub kinds(%{source: :ui} = ctx),
    do: {:ok, [FakeController.log_kind("audit"), FakeController.log_kind("relay_history")]}

  defstub files(params, %{source: :ui} = ctx), do: {:ok, %{files: [], unreachable: []}}

  defstub read(params, %{source: :ui} = ctx), do: FakeController.log_page([])

  defstub stats(params, %{source: :ui} = ctx),
    do: {:ok, %{controllers: [FakeController.log_stats_row(node())], unreachable: []}}

  defstub rotate(params, %{source: :ui} = ctx), do: {:ok, %{rotated: [], unreachable: []}}
end
