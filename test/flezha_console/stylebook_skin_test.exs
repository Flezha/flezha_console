defmodule FlezhaConsole.StylebookSkinTest do
  @moduledoc """
  Where the stylebook's skin may appear.

  Screen content is drawn with the console's own kit; the stylebook supplies the
  palette, the buttons, the tiles and the figures that fit them, the shell — rail
  and topbar — and, until its own redesign, the relay pipeline graph. So a `flz-`
  class belongs only to a button, a tile, the shell layout, the chrome form of the
  brand lockup and the graph,
  the console's stylesheets read
  colour only through its `--fcon-*` roles, and nothing here restyles the shell
  recipe, whose one home is the stylebook, except the console's one layer on it
  in `shell.css`: at desk width, the rail lifted off the page and collapsed to
  its icons.
  """

  use ExUnit.Case, async: true

  @shell "lib/flezha_console_web/components/layouts/app.html.heex"
  @graph "lib/flezha_console_web/components/topology.ex"
  @kit "lib/flezha_console_web/components/core_components.ex"

  # The chrome lockup's two classes are the kit's only borrowed skin.
  @kit_allowed ~w(flz-brand flz-logo)

  # The theme toggle is the shell's own chrome, drawn on the signed-out canvas
  # too, and the principal is drawn in both the topbar and the drawer's foot,
  # so both live with the layouts rather than in the shell template.
  @layouts "lib/flezha_console_web/components/layouts.ex"
  @layouts_allowed ~w(flz-chrome-icon-btn flz-theme-sun flz-theme-moon flz-num)

  # Every button and every tile is the stylebook's, as flezha.com wears it,
  # wherever it is drawn.
  @button ~r/^flz-button(--[a-z-]*)?$/
  @tile ~r/^flz-(tile(-foot)?|figure-(fit|value|unit))$/

  # A `data-flz-*` attribute binds a stylebook behaviour, such as the theme
  # toggle; it is not a class.
  @class ~r/(?<![\w-])flz-[a-z][a-z-]*/

  # Viewer preferences are stored under `flz-` keys, and the root layout reads
  # this one before first paint.
  @storage_keys ~w(flz-rail-collapsed)

  @shell_layer "assets/css/console/shell.css"

  defp lib_files, do: Path.wildcard("lib/**/*.{ex,heex}")

  test "a flz- class appears only on a button or a tile, in the shell, the chrome lockup and the graph" do
    strays =
      for file <- lib_files(),
          file not in [@shell, @graph],
          class <- Regex.scan(@class, File.read!(file)) |> List.flatten(),
          not Regex.match?(@button, class),
          not Regex.match?(@tile, class),
          class not in @storage_keys,
          not (file == @kit and class in @kit_allowed),
          not (file == @layouts and class in @layouts_allowed),
          uniq: true,
          do: "#{file}: #{class}"

    assert strays == [], "stylebook classes outside their places:\n" <> Enum.join(strays, "\n")
  end

  test "the console's own stylesheets read colour only through its roles" do
    for file <- ~w(assets/css/console/base.css assets/css/console/components.css #{@shell_layer}) do
      foreign =
        Regex.scan(~r/var\((--[a-z0-9-]+)/, File.read!(file), capture: :all_but_first)
        |> List.flatten()
        |> Enum.reject(&String.starts_with?(&1, "--fcon-"))
        |> Enum.uniq()

      assert foreign == [], "#{file} reads #{Enum.join(foreign, ", ")}"
    end
  end

  test "the shell recipe has one home: nothing here restyles it" do
    for file <- Path.wildcard("assets/css/**/*.css"), file != @shell_layer do
      selectors =
        Regex.scan(~r/\.flz-(?:app|app-main|canvas|sidebar|topbar)\b[^{,]*[{,]/, File.read!(file))

      assert selectors == [], "#{file} restyles the shell: #{inspect(selectors)}"
    end
  end
end
