defmodule FlezhaUiWeb.CoreComponentsTest do
  @moduledoc """
  The two components every operator form is built out of.

  Both exist to make a decision once: what a control looks like, and how wide a
  dialog is. A regression here is one a screen test would not catch — the form
  still works, it is just the wrong size or missing the hint that told the
  operator what the field means — so it is asserted at the component.
  """

  use ExUnit.Case, async: true

  use FlezhaUiWeb, :html

  import Phoenix.LiveViewTest

  describe "input/1" do
    test "a text field carries its label, value and testid" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          type="text"
          name="start[id]"
          label="Operative ID"
          value="op_1"
          maxlength="32"
          placeholder="my-operative"
          data-testid="input-operative-id"
        />
        """)

      assert html =~ "Operative ID"
      assert html =~ ~s(name="start[id]")
      assert html =~ ~s(value="op_1")
      assert html =~ ~s(maxlength="32")
      assert html =~ ~s(placeholder="my-operative")
      assert html =~ ~s(data-testid="input-operative-id")
    end

    test "a number field renders as one" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          type="number"
          name="start[snapshot_interval]"
          label="Snapshot interval"
          value=""
          data-testid="input-snapshot-interval"
        />
        """)

      assert html =~ ~s(type="number")
      assert html =~ ~s(data-testid="input-snapshot-interval")
    end

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
      assert html =~ ~s(data-testid="input-factory-id")

      # The option tag is matched whole rather than as a fixed string: which
      # attribute the serialiser writes first is not what this test is about.
      assert [chosen] = Regex.run(~r/<option[^>]*value="store_input"[^>]*>/, html)
      assert chosen =~ "selected"

      assert [other] = Regex.run(~r/<option[^>]*value="compare_filter"[^>]*>/, html)
      refute other =~ "selected"
    end

    test "a textarea holds its value and is tall enough to read a JSON object" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          type="textarea"
          name="start[init_values]"
          label="Init values"
          value={~s({"seed": 7})}
          mono
          data-testid="input-init-values"
        />
        """)

      assert html =~ "<textarea"
      assert html =~ ~s({&quot;seed&quot;: 7})
      assert html =~ "min-h-[8rem]"
      assert html =~ "form-field--mono"
    end

    test "a hint is rendered with the field, not beside it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input type="text" name="schedule[name]" label="Name" value="" hint="max 11 characters" />
        """)

      assert html =~ "flz-field-hint"
      assert html =~ "max 11 characters"
    end

    test "a field with no hint renders no hint element" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input type="text" name="schedule[cron]" label="Cron" value="" />
        """)

      refute html =~ "flz-field-hint"
    end

    test "a disabled control says so" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          type="select"
          name="start[factory_id]"
          label="Factory"
          value=""
          options={[]}
          disabled
        />
        """)

      assert html =~ "disabled"
    end
  end

  describe "dialog/1" do
    test "a confirmation is the narrowest" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.dialog testid="stop-confirm-modal" size="confirm">stop?</.dialog>
        """)

      assert html =~ "max-w-md"
    end

    test "a form dialog is wider than a confirmation" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.dialog testid="start-modal" size="form">fields</.dialog>
        """)

      assert html =~ "max-w-xl"
    end

    test "an inspection panel is the widest" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.dialog testid="dlq-inspect-modal" size="wide">payload</.dialog>
        """)

      assert html =~ "max-w-3xl"
    end

    test "a caller that names no role gets the confirmation width" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.dialog testid="plain-modal">anything</.dialog>
        """)

      assert html =~ "max-w-md"
    end

    test "the content sits in the scrolling body, so a tall form stays reachable" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.dialog testid="tall-modal" size="form">fields</.dialog>
        """)

      # `.flz-modal-body` is what carries `overflow-y: auto` under a surface
      # capped at the viewport; content rendered outside it would be cut off.
      assert html =~ ~s(<div class="flz-modal-body">fields</div>)
    end
  end
end
