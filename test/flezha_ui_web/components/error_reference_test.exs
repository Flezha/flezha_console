defmodule FlezhaUiWeb.ErrorReferenceTest do
  @moduledoc """
  The one error renderer, as it explains a controller error: its code, its
  hint, and a link to the code's family in core's errors reference.
  """

  use ExUnit.Case, async: true

  use FlezhaUiWeb, :html

  import Phoenix.LiveViewTest

  @doc false
  def render_error(error) do
    assigns = %{error: error}

    rendered_to_string(~H"""
    <.runtime_error error={@error} />
    """)
  end

  test "an error with a hint shows its code, its hint and its family's reference" do
    html =
      render_error(Flezha.Error.new("api.channel_unknown", "no channel x", "flz relay api"))

    assert html =~ "no channel x"
    assert html =~ ~s(<code data-testid="runtime-error-code">api.channel_unknown</code>)
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

  test "a transport failure keeps its message and has no reference" do
    for condition <- [:node_not_connected, :timeout] do
      html = render_error({:error, condition})

      assert html =~ ~s(data-testid="runtime-error")
      refute html =~ "runtime-error-reference"
      refute html =~ "runtime-error-code"
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

    assert html =~ "no runner serves the factory"
    assert html =~ "flz runner list"
    assert html =~ ~s(href="https://docs.flezha.com/errors.html#diagnose")
    refute html =~ "runtime-error-reason"
  end

  test "a raw reason that ends the message is set apart from the sentence" do
    reason = ~s({:poll_failing, {:failed_connect, [{:inet, [:inet], :nxdomain}]}})

    finding = %{
      level: :problem,
      code: "diagnose.plugin_unhealthy",
      message: "plugin 'p' bound to relay 'r' is unhealthy: " <> reason,
      details: %{plugin: "p", reason: reason},
      hint: nil
    }

    html = render_error(finding)

    assert html =~
             ~s(<p class="fui-note-title">plugin <code>p</code> bound to relay <code>r</code> is unhealthy.</p>)

    assert html =~ ~r/data-testid="runtime-error-reason"[^>]*>\{:poll_failing/
  end

  test "a reason in words stays in the sentence" do
    finding = %{
      code: "diagnose.plugin_unhealthy",
      message: "plugin 'p' is unhealthy: connection refused",
      details: %{reason: "connection refused"}
    }

    html = render_error(finding)

    assert html =~ "is unhealthy: connection refused"
    refute html =~ "runtime-error-reason"
  end

  test "a quoted name reads as code, while an apostrophe in a word stays" do
    html =
      render_error(%{
        code: "authz.role_insufficient",
        message: "the caller's role cannot stop relay '<b>' on runner 'r1'"
      })

    assert html =~
             "the caller&#39;s role cannot stop relay <code>&lt;b&gt;</code> on runner <code>r1</code>"
  end
end

defmodule FlezhaUiWeb.ErrorReferenceDocsUrlTest do
  # Points the reference at another address through the application
  # environment, which every rendering reads.
  use ExUnit.Case, async: false

  import FlezhaUiWeb.ErrorReferenceTest, only: [render_error: 1]

  alias FlezhaUi.TestEnv

  test "a configured docs address is the one every link uses" do
    TestEnv.put_app(:core_docs_url, "https://docs.example.test")

    html = render_error(Flezha.Error.new("authz.unknown_role"))

    assert html =~ ~s(href="https://docs.example.test/errors.html#authz")
  end
end
