defmodule FlezhaUi.StylebookSkinTest do
  @moduledoc """
  Where the stylebook's skin may appear.

  Screen content is drawn with the console's own kit; the stylebook supplies the
  palette, the shell — rail and topbar — and, until its own redesign, the relay
  pipeline graph. So a `flz-` class belongs only to the shell layout, the
  chrome form of the brand lockup and the graph, the console's stylesheets read
  colour only through its `--fui-*` roles, and nothing here restyles the shell
  recipe, whose one home is the stylebook.
  """

  use ExUnit.Case, async: true

  @shell "lib/flezha_ui_web/components/layouts/app.html.heex"
  @graph "lib/flezha_ui_web/components/topology.ex"
  @kit "lib/flezha_ui_web/components/core_components.ex"

  # The chrome lockup's two classes are the kit's only borrowed skin.
  @kit_allowed ~w(flz-brand flz-logo)

  # A `data-flz-*` attribute binds a stylebook behaviour, such as the theme
  # toggle; it is not a class.
  @class ~r/(?<![\w-])flz-[a-z][a-z-]*/

  defp lib_files, do: Path.wildcard("lib/**/*.{ex,heex}")

  test "a flz- class appears only in the shell, the chrome lockup and the graph" do
    strays =
      for file <- lib_files(),
          file not in [@shell, @graph],
          class <- Regex.scan(@class, File.read!(file)) |> List.flatten(),
          not (file == @kit and class in @kit_allowed),
          uniq: true,
          do: "#{file}: #{class}"

    assert strays == [], "stylebook classes outside their places:\n" <> Enum.join(strays, "\n")
  end

  test "the console's own stylesheets read colour only through its roles" do
    for file <- ~w(assets/css/console/base.css assets/css/console/components.css) do
      foreign =
        Regex.scan(~r/var\((--[a-z0-9-]+)/, File.read!(file), capture: :all_but_first)
        |> List.flatten()
        |> Enum.reject(&String.starts_with?(&1, "--fui-"))
        |> Enum.uniq()

      assert foreign == [], "#{file} reads #{Enum.join(foreign, ", ")}"
    end
  end

  test "the shell recipe has one home: nothing here restyles it" do
    for file <- Path.wildcard("assets/css/**/*.css") do
      selectors =
        Regex.scan(~r/\.flz-(?:app|app-main|canvas|sidebar|topbar)\b[^{,]*[{,]/, File.read!(file))

      assert selectors == [], "#{file} restyles the shell: #{inspect(selectors)}"
    end
  end
end
