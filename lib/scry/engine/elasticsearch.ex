defmodule Scry.Engine.Elasticsearch do
  @moduledoc """
  A real `Scry.Core.EngineBehaviour` implementation over
  [Elasticsearch](https://www.elastic.co/elasticsearch), replacing
  `scry_search`'s own reference implementation (`Scry.Search.Executor`
  -- a toy token-overlap relevance scorer, explicitly documented there
  as "proving the language construct executes, not an integration
  with any real search engine") with genuine `SEARCH`/`relevance()`
  execution against a real full-text search engine. Closes the
  validation the roadmap already calls for: Elasticsearch is
  `search`'s own namesake reference language, needing direct
  validation, "not just a RedisSearch stand-in."

  Like `scry_logic`/`Scry.Logic.Executor` (replaced by
  `scry_engine_episteme`) and unlike every SQL-engine adapter in this
  family, `search` has no separate "engine" tier at all in its own
  reference form -- `Scry.Search.Executor` *implements* `Scry.Core.
  EngineBehaviour` directly rather than sitting on top of one, "the
  first kind package to double as its own engine" (that module's own
  moduledoc). This package is what that same moduledoc anticipates: "a
  real backend (an actual search engine)... can implement `Scry.Core.
  EngineBehaviour` directly, however its own wire protocol actually
  works" -- it does not call `Scry.Search.Executor` at all, replacing
  its entire `WHERE`-rewrite/per-row-scoring mechanism with a genuine
  Elasticsearch Query DSL translation (`Scry.Engine.Elasticsearch.
  QueryDsl`) and a real `_search` HTTP call.

  ## Scope: `SEARCH`/`relevance()` only -- not a general Elasticsearch-as-relational-store adapter

  `Scry.Engine.Elasticsearch.QueryDsl`'s own moduledoc has the full
  reasoning: every one of `GROUP BY`/aggregates/`HAVING`/`DISTINCT`,
  and an ordinary (non-`SEARCH`) `WHERE` comparison, depends on the
  same schema-level `NOT NULL` guarantee `scry_engine_exqlite`/
  `scry_engine_duckdbex`/`scry_engine_myxql` all verify before trusting
  one -- confirmed directly, Elasticsearch's own index mapping has no
  presence/required concept to check at all, only field *type*. Rather
  than accept that gap silently, this package declines every construct
  that would need it, supporting exactly what it exists to validate:
  `SEARCH`/`relevance()`, ordinary field projection, `ORDER BY`
  (a bare field or `relevance()`), and `LIMIT`/`OFFSET`.

  ## A real, confirmed pagination-safety concern this package guards against

  Elasticsearch's own default `size` is `10`, and `hits.total` is
  itself only a lower-bound estimate past 10,000 matches unless
  `track_total_hits: true` is set (confirmed directly) -- silently
  trusting either default risks exactly the kind of silently-truncated
  result set this ecosystem's own `Scry.Core.EngineBehaviour` redesign
  exists to eliminate ("there is no partial-success return value," that
  module's own moduledoc). `QueryDsl.compile/1` always sets an explicit
  `size` (`query.limit`, or `10_000` -- Elasticsearch's own default
  `index.max_result_window` cap -- when no `limit` was given) and
  always tracks the real total hit count; `execute/3` compares the two
  and declines with `{:query_error, {:result_window_exceeded, total}}`
  rather than silently handing back a truncated page when a caller
  wrote no explicit `LIMIT` but the real match count exceeds what was
  returned. A caller wanting more than 10,000 rows back needs an
  explicit `LIMIT` of its own (subject to Elasticsearch's own
  `index.max_result_window`, a real, honest per-index setting, not a
  limit this package invents).

  No dedicated, actively-maintained Elasticsearch Elixir client exists
  that fits this package's own runtime-configured `Conn.open/1`
  convention (see `Scry.Engine.Elasticsearch.Conn`'s own moduledoc) --
  `req` talks to Elasticsearch's own plain REST API directly, building
  the Query DSL body as an ordinary Elixir map.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, EngineBehaviour, Query, QueryOps}
  alias Scry.Engine.Elasticsearch.{Conn, QueryDsl}

  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @impl true
  def execute(conn, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(conn, combined, params, __MODULE__)

  def execute(%Conn{} = conn, %Query{source: source} = query, params) do
    if Enum.any?(query.select, &match?(%Query{}, &1)) or with_bound_source?(query) do
      QueryOps.run_document(conn, query, params, __MODULE__)
    else
      execute_flat(conn, source, query, params)
    end
  end

  defp with_bound_source?(%Query{source: [name], with_bindings: with_bindings}),
    do: Map.has_key?(with_bindings, name)

  defp with_bound_source?(_query), do: false

  defp execute_flat(conn, source, query, params) do
    with {:ok, index} <- index_name(source),
         {:ok, %{body: body, query: rewritten_query}} <- QueryDsl.compile(query),
         {:ok, resp} <- search(conn, index, body) do
      rows = resp |> get_in(["hits", "hits"]) |> Enum.map(&to_row/1)
      total = get_in(resp, ["hits", "total", "value"]) || length(rows)

      if query.limit == nil and total > length(rows) do
        {:error, {:query_error, {:result_window_exceeded, total}}}
      else
        QueryOps.run_flat(rows, rewritten_query, params)
      end
    end
  end

  defp index_name([name]) when is_binary(name) do
    if Regex.match?(@identifier, name),
      do: {:ok, name},
      else: {:error, {:unsupported, {:source, name}}}
  end

  defp index_name(source), do: {:error, {:unsupported, {:source, source}}}

  defp to_row(hit) do
    Map.put(hit["_source"], QueryDsl.relevance_field(), hit["_score"] || 0)
  end

  defp search(%Conn{base_url: base_url}, index, body) do
    case Req.post(base_url <> "/" <> index <> "/_search", json: body) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{body: resp_body}} ->
        {:error, {:query_error, resp_body}}

      {:error, reason} ->
        {:error, {:query_error, reason}}
    end
  end

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback
  -- converts `source`'s own real index mapping (`GET /<index>/
  _mapping`) into `introspected_field()`s. `nullable: true` for every
  field, always -- the only honest answer available (`Scry.Engine.
  Elasticsearch.QueryDsl`'s own moduledoc has the full "no presence
  guarantee exists at all" reasoning), never a guess.
  """
  @impl true
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(%Conn{base_url: base_url}, source) do
    case Req.get(base_url <> "/" <> source <> "/_mapping") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case get_in(body, [source, "mappings", "properties"]) do
          nil -> {:ok, []}
          properties -> {:ok, Enum.map(properties, &introspected_field/1)}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{body: body}} ->
        {:error, {:introspection_error, body}}

      {:error, reason} ->
        {:error, {:introspection_error, reason}}
    end
  end

  defp introspected_field({name, %{"type" => type}}) do
    %{name: name, nullable: true, scalar: introspected_scalar(type)}
  end

  defp introspected_field({name, _mapping}), do: %{name: name, nullable: true, scalar: :unknown}

  defp introspected_scalar(type) when type in ~w(byte short integer long) do
    :integer
  end

  defp introspected_scalar(type) when type in ~w(float half_float double scaled_float) do
    :float
  end

  defp introspected_scalar(type) when type in ~w(text keyword) do
    :string
  end

  defp introspected_scalar("boolean"), do: :boolean
  defp introspected_scalar(_other), do: :unknown
end
