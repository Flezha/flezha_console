defmodule StubRemoteApi do
  @moduledoc """
  Stands in for a controller function that answers `{:error, reason}` on its
  own terms, so a test can tell a domain refusal apart from a transport
  failure. Shipped to a peer node, so it lives at the top level rather than
  under `FlezhaUi.*`.
  """

  def fails, do: {:error, :not_found}
end
