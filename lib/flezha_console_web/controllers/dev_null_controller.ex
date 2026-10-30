defmodule FlezhaConsoleWeb.DevNullController do
  @moduledoc """
  `POST /dev/null`, dev only: takes the dev stack's webhook deliveries and
  drops them unread, answering 204 so the sender counts them delivered.
  """
  use FlezhaConsoleWeb, :controller

  def create(conn, _params), do: send_resp(conn, :no_content, "")
end
