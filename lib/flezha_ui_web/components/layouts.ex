defmodule FlezhaUiWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use FlezhaUiWeb, :controller` and
  `use FlezhaUiWeb, :live_view`.
  """
  use FlezhaUiWeb, :html

  @theme_hydrate_path Path.expand(
                        "../../../assets/node_modules/@flezha/stylebook/js/theme-hydrate.js",
                        __DIR__
                      )

  File.exists?(@theme_hydrate_path) ||
    raise """
    flezha-stylebook is not installed, so the theme cannot be hydrated before
    first paint and every page would flash the wrong theme.

    Run `mix assets.setup`.
    """

  @external_resource @theme_hydrate_path
  @theme_hydrate File.read!(@theme_hydrate_path)

  embed_templates "layouts/*"

  @doc """
  Assigns `:current_path`, so the shell can mark the current destination.

  Server-side rather than in JavaScript: a client-set `aria-current` loses the
  race with LiveView's first DOM patch on a hard page load, and is dropped.
  """
  def on_mount(:current_path, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :current_path, :handle_params, fn _params,
                                                                            uri,
                                                                            socket ->
       {:cont, Phoenix.Component.assign(socket, :current_path, URI.parse(uri).path)}
     end)}
  end

  @doc """
  Whether a navigation destination is the page being shown.

  The dashboard is an exact match; everything else owns its subtree, so
  `/namespaces/default` still marks Namespaces.
  """
  def nav_current?(current, "/"), do: current == "/"
  def nav_current?(current, path), do: String.starts_with?(current, path)

  @doc """
  The stylebook's pre-paint theme hydration, inlined verbatim.

  Read at compile time and registered as an external resource, so editing the
  stylebook recompiles this module and the page pays no second blocking
  request for six lines of script.
  """
  def theme_hydrate, do: Phoenix.HTML.raw(@theme_hydrate)
end
