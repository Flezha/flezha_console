defmodule FlezhaUiWeb.ErrorReferenceTest do
  @moduledoc """
  The one error renderer, as it explains a controller error: its code, its
  hint, and a link to the code's family in core's errors reference.

  Not async: one test points the reference at another address through the
  application environment, which every rendering reads.
  """

  use ExUnit.Case, async: false

  use FlezhaUiWeb, :html

  import Phoenix.LiveViewTest

  defp render_error(error) do
    assigns = %{error: error}

    rendered_to_string(~H"""
    <.runtime_error error={@error} />
    """)
  end

  test "an error with a hint shows its code, its hint and its family's reference" do
    html =
      render_error(Flezha.Error.new("api.channel_unknown", "no channel x", "flz relay api"))

    assert html =~ "no channel x (api.channel_unknown)"
    assert html =~ ~s(data-testid="runtime-error-hint")
    assert html =~ "flz relay api"
    assert html =~ ~s(href="https://docs.flezha.com/errors.html#api")
    assert html =~ ~s(target="_blank")
  end

  test "an error without a hint renders no empty hint" do
    html = render_error(Flezha.Error.new("relay.not_found"))

    refute html =~ "runtime-error-hint"
    assert html =~ ~s(href="https://docs.flezha.com/errors.html#relay")
  end

  test "a configured docs address is the one every link uses" do
    previous = Application.fetch_env!(:flezha_ui, :core_docs_url)
    Application.put_env(:flezha_ui, :core_docs_url, "https://docs.example.test")
    on_exit(fn -> Application.put_env(:flezha_ui, :core_docs_url, previous) end)

    html = render_error(Flezha.Error.new("authz.unknown_role"))

    assert html =~ ~s(href="https://docs.example.test/errors.html#authz")
  end

  test "a transport failure keeps its message and has no reference" do
    for condition <- [:node_not_connected, :timeout] do
      html = render_error({:error, condition})

      assert html =~ ~s(data-testid="runtime-error")
      refute html =~ "runtime-error-reference"
    end
  end

  test "a diagnosis finding renders through the same component" do
    finding = %{
      level: :problem,
      code: "diagnose.no_runner",
      message: "no runner serves the factory",
      details: %{},
      hint: "flz runner list"
    }

    html = render_error(finding)

    assert html =~ "no runner serves the factory (diagnose.no_runner)"
    assert html =~ "flz runner list"
    assert html =~ ~s(href="https://docs.flezha.com/errors.html#diagnose")
  end
end
