defmodule StubRemoteApi do
  @moduledoc """
  Stands in for a controller function that answers an error on its own terms,
  as `{:error, %Flezha.Error{}}`, so a test can tell a domain failure apart from
  a transport failure. Shipped to a peer node, so it lives at the top level
  rather than under `FlezhaConsole.*`.
  """

  def fails,
    do: {:error, %Flezha.Error{code: "relay.not_found", class: :not_found, message: "no"}}
end
