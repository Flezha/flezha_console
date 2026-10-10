defmodule Mix.Tasks.Assets.Stylebook do
  @shortdoc "Copies the flezha_stylebook fonts, badger mark, favicons and mascots into priv/static"

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
  @images %{
    "logo/flezha-badger-white.svg" => "flezha-badger-white.svg",
    "honey-badger/laptop.webp" => "badger-laptop.webp",
    "honey-badger/not-found.webp" => "badger-not-found.webp"
  }
  @favicons %{
    "logo/flezha-favicon-badger-adaptive.svg" => "favicon.svg",
    "logo/flezha-favicon-badger.ico" => "favicon.ico"
  }

  @impl Mix.Task
  def run(_args) do
    package = Path.expand(@package)

    File.dir?(package) ||
      Mix.raise("""
      flezha_stylebook is not installed at #{@package}.

      The console's typefaces, badger mark, favicon and mascots all come from
      the flezha_stylebook repository, which this project depends on as an npm
      `file:` dependency and expects alongside itself at:

          #{Path.expand("../flezha_stylebook")}

      Clone it there, then run `mix assets.setup`.
      """)

    copy_fonts(package)
    copy(package, @images, "priv/static/images")
    copy(package, @favicons, "priv/static")

    Mix.shell().info("stylebook assets copied into priv/static")
  end

  defp copy_fonts(package) do
    File.mkdir_p!("priv/static/fonts")

    for font <- @fonts do
      File.cp!(Path.join([package, "fonts", font]), Path.join("priv/static/fonts", font))
    end
  end

  defp copy(package, files, dir) do
    File.mkdir_p!(dir)

    for {from, to} <- files do
      File.cp!(Path.join([package, "assets", from]), Path.join(dir, to))
    end
  end
end
