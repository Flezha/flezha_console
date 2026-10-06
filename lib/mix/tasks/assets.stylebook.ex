defmodule Mix.Tasks.Assets.Stylebook do
  @shortdoc "Copies the flezha_stylebook fonts, lockups and favicons into priv/static"

  @moduledoc """
  Places the `flezha_stylebook` static assets the console serves into
  `priv/static`.

  The stylebook's `@font-face` rules resolve `../fonts/*.woff2` relative to the
  served stylesheet, so the faces have to exist at `priv/static/fonts/`. The
  `web` container has no Node, so nothing can fetch them at boot — this task
  runs on the host and its output is committed.

  Fails when the stylebook is not installed, rather than leaving the console to
  render unstyled with no explanation.
  """

  use Mix.Task

  @package "assets/node_modules/@flezha/stylebook"
  @fonts ~w(Inter-latin.woff2 JetBrainsMono-latin.woff2 SpaceGrotesk-latin.woff2)
  @favicon "flezha-favicon-purple.svg"
  @favicon_raster "flezha-favicon-purple-32.png"

  @impl Mix.Task
  def run(_args) do
    package = Path.expand(@package)

    File.dir?(package) ||
      Mix.raise("""
      flezha_stylebook is not installed at #{@package}.

      The console's typefaces, brand lockups and favicon all come from the
      flezha_stylebook repository, which this project depends on as an npm
      `file:` dependency and expects alongside itself at:

          #{Path.expand("../flezha_stylebook")}

      Clone it there, then run `mix assets.setup`.
      """)

    copy_fonts(package)
    copy_lockups(package)
    copy_favicons(package)

    Mix.shell().info("stylebook assets copied into priv/static")
  end

  defp copy_fonts(package) do
    File.mkdir_p!("priv/static/fonts")

    for font <- @fonts do
      File.cp!(Path.join([package, "fonts", font]), Path.join("priv/static/fonts", font))
    end
  end

  defp copy_lockups(package) do
    File.mkdir_p!("priv/static/images")

    for lockup <- Path.wildcard(Path.join([package, "assets", "flezha-ui-*.svg"])) do
      File.cp!(lockup, Path.join("priv/static/images", Path.basename(lockup)))
    end
  end

  defp copy_favicons(package) do
    File.cp!(Path.join([package, "assets", @favicon]), "priv/static/favicon.svg")

    Path.join([package, "assets", @favicon_raster])
    |> File.read!()
    |> ico()
    |> then(&File.write!("priv/static/favicon.ico", &1))
  end

  # An ICO container wrapping the stylebook's 32px PNG verbatim — the format
  # allows a PNG payload, so this is a real .ico rather than a PNG under the
  # wrong extension. Header is 6 bytes of ICONDIR plus one 16-byte entry, so
  # the image starts at offset 22.
  defp ico(png) do
    <<0::little-16, 1::little-16, 1::little-16, 32, 32, 0, 0, 1::little-16, 32::little-16,
      byte_size(png)::little-32, 22::little-32>> <> png
  end
end
