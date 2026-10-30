defmodule FlezhaConsoleWeb.EndpointTest do
  use ExUnit.Case, async: true

  alias FlezhaConsoleWeb.Endpoint

  defp level(path), do: Endpoint.log_level(Plug.Test.conn(:get, path))

  describe "the request log" do
    test "keeps a login or confirmation token out of the info log" do
      assert level("/users/log-in/a-token") == :debug
      assert level("/users/settings/confirm-email/a-token") == :debug
    end

    test "logs every other request at info, the login form included" do
      assert level("/users/log-in") == :info
      assert level("/namespaces/default") == :info
    end

    test "leaves the dev webhook receiver out" do
      assert level("/dev/null") == false
    end
  end
end
