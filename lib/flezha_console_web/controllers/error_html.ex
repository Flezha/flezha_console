defmodule FlezhaConsoleWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use FlezhaConsoleWeb, :html

  embed_templates "error_html/*"

  # Any status without a page of its own renders as plain text named after
  # it, for example "500.html" becomes "Internal Server Error".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
