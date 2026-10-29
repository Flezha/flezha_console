defmodule FlezhaConsoleWeb.ListingView do
  @moduledoc """
  What a listing shows: its search text (`q`), its filters and its sort, as
  one map of strings that the query string carries and the controller is
  asked by.

  A listing declares its view once:

      @view ListingView.declare(
        search: :text,
        filters: [health: :health, runner: :runner],
        sorts: [id: "By id", severity: "Most severe first"]
      )

  `search` and each filter name the controller filter they become, or `nil`
  for one the listing applies itself. The first sort is the default, and
  `defaults` may give a filter another. `parse/2` reads a view from params,
  keeping only what is declared; `query/2` writes it back without its
  defaults; `opts/3` asks the controller for a page of it.
  """

  # A value comes from the address bar or a form, so it is bounded.
  @max_value_bytes 256

  @doc "A listing's view declaration."
  def declare(opts) do
    filters = Keyword.get(opts, :filters, [])
    sorts = Keyword.fetch!(opts, :sorts)
    [{default_sort, _label} | _] = sorts

    defaults =
      filters
      |> Map.new(fn {key, _controller} -> {to_string(key), ""} end)
      |> Map.merge(%{"q" => "", "sort" => to_string(default_sort)})
      |> Map.merge(Keyword.get(opts, :defaults, %{}))

    %{
      search: Keyword.get(opts, :search),
      filters: Map.new(filters, fn {key, controller} -> {to_string(key), controller} end),
      sorts: sorts,
      defaults: defaults
    }
  end

  @doc "The view with nothing chosen."
  def default(spec), do: spec.defaults

  @doc "The sorts a listing offers, as `{value, label}` for its picker."
  def sorts(spec), do: Enum.map(spec.sorts, fn {sort, label} -> {to_string(sort), label} end)

  @doc """
  The view `params` ask for: each declared key, its default when `params`
  hold none or one too long, and a sort the listing does not offer read as
  its default.
  """
  def parse(spec, params) do
    params = params || %{}
    Map.new(spec.defaults, fn {key, default} -> {key, value(spec, key, params[key], default)} end)
  end

  defp value(spec, "sort", written, default) do
    if Enum.any?(spec.sorts, fn {sort, _label} -> to_string(sort) == written end),
      do: written,
      else: default
  end

  defp value(_spec, _key, written, _default)
       when is_binary(written) and byte_size(written) <= @max_value_bytes,
       do: written

  defp value(_spec, _key, _written, default), do: default

  @doc "The query string of `view`: every value it holds but a default or a blank."
  def query(spec, view) do
    view
    |> Map.take(Map.keys(spec.defaults))
    |> Enum.reject(fn {key, value} -> value in ["", spec.defaults[key]] end)
    |> Map.new()
  end

  @doc """
  The controller `opts` for a page of `limit` rows of `view`: its sort, its
  search as the declared search filter, and each filter the controller
  applies. A blank value asks for nothing.
  """
  def opts(spec, view, limit) do
    asked = Map.new(view, fn {key, value} -> {key, String.trim(to_string(value))} end)

    filters =
      for {key, controller} <- Enum.sort(spec.filters),
          controller != nil,
          asked[key] not in [nil, ""],
          do: {controller, asked[key]}

    filters =
      if spec.search && asked["q"] not in [nil, ""],
        do: [{spec.search, asked["q"]} | filters],
        else: filters

    [limit: limit, sort: sort(spec, view["sort"]), filter: filters]
  end

  defp sort(spec, written) do
    Enum.find_value(spec.sorts, fn {sort, _label} -> to_string(sort) == written && sort end) ||
      spec.sorts |> hd() |> elem(0)
  end
end
