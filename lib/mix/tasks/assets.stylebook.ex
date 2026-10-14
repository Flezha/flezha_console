defmodule Mix.Tasks.Assets.Stylebook do
  @shortdoc "Copies the flezha_stylebook logo, favicons, mascot and typefaces into priv/static"

  @moduledoc """
  Places the `flezha_stylebook` brand assets the console serves into
  `priv/static`: the Flezha UI lockup, the favicons, the not-found mascot and
  the three typefaces flezha.com sets type in.

  The `web` container has no Node, so nothing can fetch them at boot — this
  task runs on the host and its output is committed. The fonts land in
  `priv/static/fonts`, where the stylebook's `fonts.css` finds them relative to
  the compiled `/assets/app.css`.

  Fails when the stylebook is not installed, rather than leaving the console to
  render unstyled with no explanation.
  """

  use Mix.Task

  @package "assets/node_modules/@flezha/stylebook"
  @images %{
    "assets/logo/flezha-ui-badger-line-text-white.svg" => "flezha-ui-badger-line-text-white.svg",
    "assets/logo/flezha-favicon-badger-mark-dark-32.png" => "favicon-mark-dark-32.png",
    "assets/logo/flezha-favicon-badger-mark-white-32.png" => "favicon-mark-white-32.png",
    "assets/honey-badger/not-found.png" => "badger-not-found.png"
  }
  @favicons %{"assets/logo/flezha-favicon-badger-adaptive.svg" => "favicon.svg"}
  @fonts ~w(Inter-latin.woff2 JetBrainsMono-latin.woff2 SpaceGrotesk-latin.woff2)

  @impl Mix.Task
  def run(_args) do
    package = Path.expand(@package)

    File.dir?(package) ||
      Mix.raise("""
      flezha_stylebook is not installed at #{@package}.

      The console's logo, favicon, mascot and typefaces all come from
      the flezha_stylebook repository, which this project depends on as an npm
      `file:` dependency and expects alongside itself at:

          #{Path.expand("../flezha_stylebook")}

      Clone it there, then run `mix assets.setup`.
      """)

    copy(package, @images, "priv/static/images")
    copy(package, @favicons, "priv/static")
    copy(package, Map.new(@fonts, &{"fonts/#{&1}", &1}), "priv/static/fonts")

    Mix.shell().info("stylebook assets copied into priv/static")
  end

  defp copy(package, files, dir) do
    File.mkdir_p!(dir)

    for {from, to} <- files do
      File.cp!(Path.join(package, from), Path.join(dir, to))
    end
  end
end
