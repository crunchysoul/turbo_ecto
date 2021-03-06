defmodule Turbo.Ecto.Hooks.Search do
  @moduledoc """
  This module provides a operations that can add searching functionality to
  a pipeline of `Ecto` queries. This module works by taking fields.
  """

  import Ecto.Query

  alias Turbo.Ecto.Services.BuildSearchQuery
  alias Turbo.Ecto.Utils

  @doc """
  Builds a search `Ecto.Query.t` on top of a given `Ecto.Query.t` variable
  with given `params`.

  ## Example

  When search_type is `:like`

      iex> params = %{"q" => %{"name_like" => "elixir"}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in Turbo.Ecto.Product), where: like(p.name, ^"%elixir%")>

  When search_type is `:ilike`

      iex> params = %{"q" => %{"name_ilike" => "elixir"}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in Turbo.Ecto.Product), where: ilike(p.name, ^"%elixir%")>

  When search_type is `:eq`

      iex> params = %{"q" => %{"price_eq" => 100}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in Turbo.Ecto.Product), where: p.price == ^100>

  When search_type is `:gt`

      iex> params = %{"q" => %{"price_gt" => 100}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in Turbo.Ecto.Product), where: p.price > ^100>

  When search_type is `:lt`

      iex> params = %{"q" => %{"price_lt" => 100}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in Turbo.Ecto.Product), where: p.price < ^100>

  When search_type is `:gteq`

      iex> params = %{"q" => %{"price_gteq" => 100}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in Turbo.Ecto.Product), where: p.price >= ^100>

  When search_type is `:lteq`

      iex> params = %{"q" => %{"price_lteq" => 100}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in Turbo.Ecto.Product), where: p.price <= ^100>

  when use `and` symbol condition

      iex> params = %{"q" => %{"name_and_body_like" => "elixir"}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in subquery(from p in Turbo.Ecto.Product),
        where: like(p.body, ^"%elixir%")), where: like(p.name, ^"%elixir%")>

  when use `or` symbol condition

      iex> params = %{"q" => %{"name_or_body_like" => "elixir"}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in subquery(from p in Turbo.Ecto.Product),
        where: like(p.name, ^"%elixir%")), or_where: like(p.body, ^"%elixir%")>

  when use `assoc`

      iex> params = %{"q" => %{"category_name_like" => "elixir"}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in Turbo.Ecto.Product), join: c in assoc(p, :category), where: like(c.name, ^"%elixir%")>

  when use `and` && `or` && `assoc` condition

      iex> params = %{"q" => %{"category_name_or_name_and_body_like" => "elixir"}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Product, params)
      #Ecto.Query<from p in subquery(from p in subquery(from p in subquery(from p in Turbo.Ecto.Product),
        where: like(p.body, ^"%elixir%")),
        join: c in assoc(p, :category),
        where: like(c.name, ^"%elixir%")), or_where: like(p.name, ^"%elixir%")>

  when multi association && `or` && `and` condition

      iex> params = %{"q" => %{"product_category_name_and_product_name_or_name_like" => "elixir"}}
      iex> Turbo.Ecto.Hooks.Search.run(Turbo.Ecto.Variant, params)
      #Ecto.Query<from v in subquery(from v in subquery(from v in subquery(from v in Turbo.Ecto.Variant),
        join: p in assoc(v, :product),
        join: c in assoc(p, :category),
        where: like(c.name, ^"%elixir%")),
        join: p in assoc(v, :product),
        where: like(p.name, ^"%elixir%")), or_where: like(v.name, ^"%elixir%")>

  """
  @spec run(Ecto.Query.t(), Map.t()) :: Ecto.Query.t()
  def run(queryable, search_params), do: handle_search(queryable, search_params)

  defp handle_search(queryable, search_params) do
    search_params
    |> Map.get("q", %{})
    |> Enum.reduce(%{}, &build_search_mapbox(&1, &2, queryable))
    |> Enum.sort_by(fn({_, b}) -> byte_size(b.search_expr) end)
    |> Enum.reduce(queryable, &search_queryable(&1, &2))
  end

  # Generate search mapbox from search params.
  def build_search_mapbox({search_field_and_type, search_term}, mapbox, queryable) do
    search_regex = ~r/([a-z1-9_]+)_(#{decorator_search_types()})$/

    if Regex.match?(search_regex, search_field_and_type) do
      [_, match, search_type] = Regex.run(search_regex, search_field_and_type)

      match
      |> build_and_condition()
      |> Enum.reduce(%{}, &build_or_condition(&1, &2))
      |> Enum.reduce(mapbox, &build_assoc_query(&1, &2, search_term, search_type, queryable))
    else
      raise "Unknown search matchers, #{inspect search_field_and_type}\n" <>
      "it should be endwith one of #{inspect decorator_search_types()}, click: https://github.com/zven21/turbo_ecto#search-matchers"
    end
  end

  # Build with `and` expr condition from search params.
  defp build_and_condition(field) do
    field
    |> String.split(~r{(_and_)})
    |> Enum.reduce(%{}, &(Map.put(&2, &1, "where")))
  end

  # Build with `or` expr cnndition from search params.
  defp build_or_condition({search_field, _}, search_mapbox) do
    [hd | tl] = String.split(search_field, ~r{(_or_)})

    tl
    |> Enum.reduce(search_mapbox, &(Map.put(&2, &1, "or_where")))
    |> Map.put(hd, "where")
  end

  # Build with assoc tables.
  defp build_assoc_query({search_field, search_expr}, mapbox, search_term, search_type, queryable),
    do: do_build_assoc_query(search_field, search_field, search_type, search_term, search_expr, queryable, mapbox)

  defp do_build_assoc_query(search_field, field, search_type, search_term, search_expr, queryable, mapbox, assoc \\ []) do
    # Returns string of the queryable's associations.
    assoc_tables = Enum.join(Utils.schema_from_query(queryable).__schema__(:associations), "|")

    association_regex = ~r{^(#{assoc_tables})}
    split_regex = ~r/^(#{assoc_tables})_([a-z_]+)/

    cond do
      String.to_atom(search_field) in Utils.schema_from_query(queryable).__schema__(:fields) ->
        Map.put(mapbox, field,
          %{
            assoc: assoc,
            search_field: String.to_atom(search_field),
            search_expr:  search_expr,
            search_type:  String.to_atom(search_type),
            search_term:  search_term
          }
        )

      Regex.match?(association_regex, search_field) ->
        [_, assoc_table, search_field] = Regex.run(split_regex, search_field)
        assoc_table = String.to_atom(assoc_table)
        assoc_queryable = Utils.schema_from_query(queryable).__schema__(:association, assoc_table).related
        assoc = assoc ++ [assoc_table]
        # `search_field` may be in the assco table
        do_build_assoc_query(search_field, field, search_type, search_term, search_expr, assoc_queryable, mapbox, assoc)

      true -> mapbox
    end
  end

  # Generate search queryable.
  defp search_queryable({_, map}, queryable) do

    assoc = Map.get(map, :assoc)
    search_field = Map.get(map, :search_field)
    search_type = Map.get(map, :search_type)
    search_term = Map.get(map, :search_term)
    search_expr = String.to_atom(Map.get(map, :search_expr))

    assoc
    |> Enum.reduce(from(e in subquery(queryable)), &join_by_assoc(&1, &2))
    |> BuildSearchQuery.run(search_field, {search_expr, search_type}, search_term)
  end
  defp search_queryable(_, queryable), do: queryable

  # Helper function which handles associations in a query with a join type.
  defp join_by_assoc(assoc, queryable) do
    join(queryable, :inner, [..., p1], p2 in assoc(p1, ^assoc))
  end

  defp decorator_search_types, do: BuildSearchQuery.search_types |> Enum.join("|")
end
