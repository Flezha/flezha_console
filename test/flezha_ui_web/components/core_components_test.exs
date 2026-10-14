defmodule FlezhaUiWeb.CoreComponentsTest do
  @moduledoc """
  The components every operator form is built out of, and the banner every
  controller error is shown in.

  Each exists to make a decision once: what a control looks like, how wide a
  dialog is, and how an error reads. A regression here is one a screen test would not catch — the form
  still works, it is just the wrong size or missing the hint that told the
  operator what the field means — so it is asserted at the component.
  """

  use ExUnit.Case, async: true

  use FlezhaUiWeb, :html

  import Phoenix.LiveViewTest

  describe "input/1" do
    test "a select offers its options and marks the chosen one" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          type="select"
          name="start[factory_id]"
          label="Factory"
          value="store_input"
          prompt="Select a factory..."
          options={[{"store_input", "store_input"}, {"compare_filter", "compare_filter"}]}
          data-testid="input-factory-id"
        />
        """)

      assert html =~ "Select a factory..."

      # The option tag is matched whole rather than as a fixed string: which
      # attribute the serialiser writes first is not what this test is about.
      assert [chosen] = Regex.run(~r/<option[^>]*value="store_input"[^>]*>/, html)
      assert chosen =~ "selected"

      assert [other] = Regex.run(~r/<option[^>]*value="compare_filter"[^>]*>/, html)
      refute other =~ "selected"
    end

    test "a hint renders with the field only when one is given" do
      assigns = %{}

      hinted =
        rendered_to_string(~H"""
        <.input type="text" name="schedule[name]" label="Name" value="" hint="max 11 characters" />
        """)

      plain =
        rendered_to_string(~H"""
        <.input type="text" name="schedule[cron]" label="Cron" value="" />
        """)

      assert hinted =~ ~r/class="fui-hint"[^>]*>\s*max 11 characters/
      refute plain =~ "fui-hint"
    end
  end

  describe "button/1" do
    test "a button with its own click handler does not submit its form" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <form><.button phx-click="close">Cancel</.button></form>
        """)

      assert html =~ ~s(type="button")
    end

    test "an explicit type is kept, and a plain button is left to its form" do
      assigns = %{}

      submit = rendered_to_string(~H|<.button type="submit" phx-click="go">Go</.button>|)
      plain = rendered_to_string(~H|<.button>Go</.button>|)

      assert submit =~ ~s(type="submit")
      refute plain =~ "type="
    end
  end

  describe "dialog/1" do
    test "the content sits in the scrolling body, so a tall form stays reachable" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.dialog testid="tall-modal" size="form">fields</.dialog>
        """)

      # `.fui-dialog-body` is what carries `overflow-y: auto` under a surface
      # capped at the viewport; content rendered outside it would be cut off.
      assert html =~ ~s(<div class="fui-dialog-body">fields</div>)
    end
  end

  describe "runtime_error/1" do
    test "a refusal names the action, the controller's message and the code" do
      assigns = %{
        error: Flezha.Error.new("authz.role_insufficient", "your role does not allow this")
      }

      html =
        rendered_to_string(~H"""
        <.runtime_error error={@error} action="the stop" />
        """)

      assert html =~ "The controller refused the stop"
      assert html =~ "your role does not allow this"
      assert html =~ "authz.role_insufficient"
      refute html =~ "Store a flezha token"
    end

    test "a refusal for want of an identity links to settings" do
      for code <- ~w(authz.principal_not_bound authz.no_role_binding) do
        assigns = %{error: {:error, Flezha.Error.new(code)}}

        html =
          rendered_to_string(~H"""
          <.runtime_error error={@error} />
          """)

        assert html =~ "Store a flezha token in settings"
      end
    end

    test "another failure shows the controller's message and its hint" do
      assigns = %{
        error:
          Flezha.Error.new("relay.not_running", "relay 'r1' is not running", "start it first")
      }

      html =
        rendered_to_string(~H"""
        <.runtime_error error={@error} />
        """)

      assert html =~ "relay <code>r1</code> is not running"
      assert html =~ ~s(data-testid="runtime-error-hint")
      assert html =~ "start it first"
      refute html =~ "refused"
    end

    test "a transport condition reads in the same banner" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.runtime_error error={:node_not_connected} />
        """)

      assert html =~ "Not connected to a flezha controller"
    end

    test "nothing renders without an error" do
      assigns = %{}

      assert rendered_to_string(~H"""
             <.runtime_error error={nil} />
             """) =~ ~r/^\s*$/
    end
  end

  describe "error_message/2" do
    test "decides by class and code, never by the message text" do
      denied = Flezha.Error.new("authz.namespace_mismatch", "elsewhere")
      missing = Flezha.Error.new("plugin.not_found", "refused by nobody")

      assert error_message(denied, "the read") ==
               "The controller refused the read: elsewhere (authz.namespace_mismatch)"

      assert error_message(missing) == "refused by nobody (plugin.not_found)"
    end

    test "a condition only this node sees is stated in words alone" do
      assert error_message(:timeout) == "The flezha controller did not answer in time."
    end
  end
end
