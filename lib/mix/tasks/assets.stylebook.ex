defmodule Mix.Tasks.Assets.Stylebook do
  @shortdoc "Copies the flezha_stylebook logo, favicons and mascots into priv/static"

  @moduledoc """
  Places the `flezha_stylebook` brand assets the console serves into
  `priv/static`: the Flezha UI lockup, the favicons and the two mascot poses.

  The `web` container has no Node, so nothing can fetch them at boot — this
  task runs on the host and its output is committed. The console's typefaces
  are its own and live in `priv/static/fonts` already.

  Fails when the stylebook is not installed, rather than leaving the console to
  render unstyled with no explanation.
  """

  use Mix.Task

  @package "assets/node_modules/@flezha/stylebook"
  @images %{
    "logo/flezha-ui-badger-line-text-white.svg" => "flezha-ui-badger-line-text-white.svg",
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

      The console's logo, favicon and mascots all come from
      the flezha_stylebook repository, which this project depends on as an npm
      `file:` dependency and expects alongside itself at:

          #{Path.expand("../flezha_stylebook")}

      Clone it there, then run `mix assets.setup`.
      """)

    copy(package, @images, "priv/static/images")
    copy(package, @favicons, "priv/static")

    Mix.shell().info("stylebook assets copied into priv/static")
  end

  defp copy(package, files, dir) do
    File.mkdir_p!(dir)

    for {from, to} <- files do
      File.cp!(Path.join([package, "assets", from]), Path.join(dir, to))
    end
  end
end
