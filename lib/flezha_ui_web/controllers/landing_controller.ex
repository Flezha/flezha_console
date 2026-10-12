defmodule FlezhaUiWeb.LandingController do
  @moduledoc """
  `/`: the Home of the namespace the operator last worked in.

  A redirect rather than a screen of its own, so the address bar always names
  the scope being shown. A remembered namespace the token no longer reaches
  falls back to the first one it does, and a token reaching none to the
  namespace list, which says so.
  """
  use FlezhaUiWeb, :controller

  alias FlezhaUi.Service.NodeManager

  def show(conn, _params) do
    scope = conn.assigns.current_scope

    {reachable, _error} =
      scope |> FlezhaUi.Accounts.Scope.flezha_token() |> NodeManager.scoped_namespaces()

    redirect(conn, to: FlezhaUiWeb.Layouts.landing(scope.user.last_namespace, reachable))
  end
end
