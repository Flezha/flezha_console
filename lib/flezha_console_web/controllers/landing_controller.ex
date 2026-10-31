defmodule FlezhaConsoleWeb.LandingController do
  @moduledoc """
  `/`: the Dashboard of the namespace the operator last worked in.

  A redirect rather than a screen of its own, so the address bar always names
  the scope being shown. A remembered namespace the token no longer reaches
  falls back to the first one it does, and a token reaching none to the
  namespace list, which says so.

  Also the not-found page for any address no other route takes, and the old
  address of the audit log, which is a kind of the Logs screen.
  """
  use FlezhaConsoleWeb, :controller

  alias FlezhaConsole.Service.NodeManager

  def show(conn, _params) do
    scope = conn.assigns.current_scope

    {reachable, _error} =
      scope |> FlezhaConsole.Accounts.Scope.flezha_token() |> NodeManager.scoped_namespaces()

    redirect(conn, to: FlezhaConsoleWeb.Layouts.landing(scope.user.last_namespace, reachable))
  end

  def audit(conn, _params) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    redirect(conn, to: "/logs/audit" <> query)
  end

  # Answered rather than raised, so dev's debugger keeps to real failures and an
  # unknown address shows the same page in every environment.
  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_layout(false)
    |> put_view(html: FlezhaConsoleWeb.ErrorHTML)
    |> render(:"404")
  end
end
