defmodule Scry.Engine.Elasticsearch.QueryDsl do
  @moduledoc """
  Compiles a flat `Scry.Core.Query.t()` into a real Elasticsearch
  Query DSL request body -- `WHERE`/`ORDER BY`/`LIMIT`/`OFFSET`,
  `relevance()` included -- for `Scry.Engine.Elasticsearch`'s own
  `execute/3`. All-or-nothing, the same `Scry.Core.EngineBehaviour.
  execute/3` posture every SQL-engine sibling in this family already
  established: `compile/1` returns `{:error, {:unsupported, detail}}`
  the moment anything in `query` falls outside what this module
  translates.

  ## What compiles

  - `wheres`: every leaf must be `{:variant, {:search, left, needle}}`
    (the `<field> SEARCH <string>` form, `left` a bare
    field path -- `Scry.Search.Executor`'s own scope limit on the
    reference implementation this package replaces, kept here too) --
    a real `{:cmp, ...}`/`{:in, ...}` ordinary predicate leaf declines
    the whole query. See "Why ordinary WHERE comparisons are out of
    scope" below for why, not just what.
  - `{:and, l, r}` becomes a `bool.must` query; `{:or, l, r}` becomes a
    `bool.should` query with `minimum_should_match: 1` set explicitly,
    always -- confirmed directly against a real cluster: `should`
    alone defaults to requiring at least one match, but that default
    silently flips to "optional, score-only" the moment the query is
    later nested inside a `bool` that also has a `must`/`filter`
    clause (a real, confirmed trap for exactly the kind of recursive
    combinator nesting `{:and, {:or, ...}, ...}` builds) -- setting it
    explicitly, every time, sidesteps the trap regardless of nesting
    context rather than relying on it never happening to apply.
    `{:not, p}` becomes `bool.must_not`.
  - `order_bys`: a bare field becomes an ordinary Elasticsearch `sort`
    entry; `relevance()` becomes `{"_score": direction}`. Any `sort`
    clause other than a bare `_score` stops Elasticsearch from
    computing `_score` at all unless `track_scores: true` is also set
    (confirmed directly) -- always included whenever `order_bys` is
    non-empty, so `relevance()` still resolves correctly in `select`
    even when the actual sort key is an ordinary field.
  - `limit`/`offset` become `size`/`from`. `track_total_hits: true` is
    always set (Elasticsearch's own total-hit count is capped, and
    reported as only a lower bound, past 10,000 by default otherwise)
    so `Scry.Engine.Elasticsearch.execute/3` can reliably tell a fully
    page-in-window result apart from one Elasticsearch silently
    truncated -- see that module's own moduledoc for the check this
    makes with it.
  - `relevance()` anywhere in `select` is rewritten to an ordinary
    field reference against a fresh, per-row `_scry_relevance` value
    (populated from that hit's own real `_score`) -- the identical
    `select`-side rewrite `Scry.Search.Executor` already does for its
    own toy score, reused here verbatim since core's own `Scry.Core.
    QueryOps.run_flat/3` needs the identical ordinary-field shape
    either way; only the *source* of the number is real here.

  ## What's declined outright, and why

  `GROUP BY`/any aggregate call in `select`, `HAVING`, and `DISTINCT`
  are all declined -- not merely unimplemented, but genuinely out of
  scope for a real reason: every one of those, like an ordinary `WHERE`
  comparison, ultimately depends on the same null-safety guarantee
  `scry_engine_exqlite`/`scry_engine_duckdbex`/`scry_engine_myxql` all
  verify via a real schema-level `NOT NULL` check before trusting a
  comparison or an aggregate. **Elasticsearch has no equivalent to
  verify against at all** -- confirmed directly: an index mapping
  declares a field's own *type*, never a presence/required guarantee,
  and any document can omit any field with no schema violation
  whatsoever (a `term`/`range` query, or an aggregation, against a
  field missing on some documents simply, silently excludes those
  documents rather than erroring). There is no honest way to build the
  same kind of pre-flight check `Scry.Engine.Myxql.Schema.verify/4`
  makes when the underlying store has no concept of the guarantee
  being checked. Rather than silently accept that gap the way SQLite's
  own weak typing was found to need real guarding against, this
  package declines every construct that would need it -- `SEARCH`/
  `relevance()` (this package's own actual reason to exist, per
  its own roadmap entry: "needs direct validation, not
  just a RedisSearch stand-in") never depend on it in the first place,
  since a `match` query's own "no match" case is already the correct,
  intended behavior for an absent field, not a null-safety violation.
  """

  alias Scry.Core.Query

  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @relevance_field "_scry_relevance"
  @default_size 10_000

  @typedoc "A compiled request: the JSON-ready body map, and `query` with `relevance()` already rewritten for `Scry.Core.QueryOps.run_flat/3`."
  @type compiled :: %{body: map(), query: Query.t()}

  @doc """
  Compiles `query` into a real Elasticsearch Query DSL request body,
  all-or-nothing -- this module's own moduledoc has the complete "what
  compiles" reasoning.
  """
  @spec compile(Query.t()) :: {:ok, compiled()} | {:error, {:unsupported, term()}}
  def compile(%Query{} = query) do
    with :ok <- check(query.havings == [], {:construct, :having}),
         :ok <- check(not aggregate_query?(query), {:construct, :group_by}),
         :ok <- check(not query.distinct, {:construct, :distinct}),
         {:ok, es_query} <- translate_wheres(query.wheres),
         {:ok, sort} <- translate_order_bys(query.order_bys) do
      body =
        %{
          query: es_query,
          from: query.offset || 0,
          size: query.limit || @default_size,
          track_total_hits: true
        }
        |> maybe_put_sort(sort)

      # `wheres`/`order_bys`/`limit`/`offset` are all cleared, not
      # merely rewritten -- Elasticsearch has already fully and
      # authoritatively evaluated *and paginated* the query server-side
      # (`es_query`'s own `bool`/`must`/`should`/`must_not` structure
      # faithfully mirrors the original `AND`/`OR`/`NOT` nesting; `sort`
      # mirrors `order_bys`; `from`/`size` mirror `offset`/`limit`), so
      # every row this query returns is already, genuinely correct and
      # in final order. Found the hard way, not designed in up front:
      # `Scry.Core.QueryOps.run_flat/3` doesn't just apply projection --
      # it *also* re-evaluates `wheres` and re-applies `order_bys`/
      # `limit`/`offset` generically (the mechanism `Scry.Search.
      # Executor`'s own toy scorer actually needs, since it can only
      # ever determine a match by inspecting one row at a time and
      # relies on `run_flat/3`'s own generic evaluator for everything
      # downstream of that). Left populated, each one either crashes
      # outright (an unresolved `{:variant, {:search, ...}}` `WHERE`
      # leaf, or a bare `relevance()` `order_bys` key core's own
      # generic sort has no function named that for) or silently
      # re-applies pagination on top of pagination that already
      # happened (confirmed directly: `LIMIT 1 OFFSET 1` against a
      # 2-row, already-offset-by-Elasticsearch single-row result
      # skips that one remaining row too, returning nothing). This
      # module's own translation is authoritative pushdown, not
      # per-row scoring -- `run_flat/3` is used for exactly one thing
      # here, final projection into `select`'s own shape.
      rewritten_query = %{
        query
        | wheres: [],
          order_bys: [],
          limit: nil,
          offset: nil,
          select: Enum.map(query.select, &rewrite_relevance_body_item/1)
      }

      {:ok, %{body: body, query: rewritten_query}}
    end
  end

  defp check(true, _detail), do: :ok
  defp check(false, detail), do: {:error, {:unsupported, detail}}

  defp aggregate_query?(query),
    do: query.group_bys != [] or Enum.any?(query.select, &aggregate_body_item?/1)

  @aggregate_names ~w(sum avg count min max)
  defp aggregate_body_item?({:computed, _alias, {:call, name, _args}}),
    do: name in @aggregate_names

  defp aggregate_body_item?(_other), do: false

  defp maybe_put_sort(body, nil), do: body

  defp maybe_put_sort(body, sort),
    do: body |> Map.put(:sort, sort) |> Map.put(:track_scores, true)

  # ---- WHERE -> bool query ---------------------------------------------

  defp translate_wheres([]), do: {:ok, %{match_all: %{}}}

  # The single-predicate case is used directly, not wrapped in an
  # extra outer `bool.must: [...]` -- found by property test, not
  # assumed: that extra wrapping layer is semantically a no-op for
  # *matching* (still exactly the same documents), but a real,
  # confirmed Elasticsearch scoring quirk when the one wrapped clause
  # is itself a `bool.should`: two documents that score genuinely
  # differently unwrapped come back with *identical* `_score` values
  # once wrapped, silently turning `ORDER BY relevance()` into a tie
  # broken by an arbitrary, direction-independent internal order
  # instead. `wheres` with two or more predicates still needs the
  # `must` wrapper for real (there's more than one clause to combine),
  # where the identical quirk was never observed.
  defp translate_wheres([predicate]), do: translate_predicate(predicate)

  defp translate_wheres(wheres) do
    with {:ok, clauses} <- translate_all(wheres) do
      {:ok, %{bool: %{must: clauses}}}
    end
  end

  defp translate_all(predicates) do
    Enum.reduce_while(predicates, {:ok, []}, fn predicate, {:ok, acc} ->
      case translate_predicate(predicate) do
        {:ok, es_query} -> {:cont, {:ok, acc ++ [es_query]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp translate_predicate({:variant, {:search, left, needle}}) when is_list(left) do
    if Enum.all?(left, &identifier?/1) do
      {:ok, %{match: %{Enum.join(left, ".") => needle}}}
    else
      {:error, {:unsupported, {:construct, :search_field}}}
    end
  end

  # `left` is a `{:call, ...}`/`{:dot, ...}`, not a bare field path --
  # the grammar allows it, `Scry.Search.Executor`'s own reference
  # implementation raises for it, this module declines cleanly instead
  # (a compile-time check is available here that isn't there, since
  # this module never touches a row at all).
  defp translate_predicate({:variant, {:search, _left, _needle}}) do
    {:error, {:unsupported, {:construct, :search_lhs_not_a_field}}}
  end

  defp translate_predicate({:and, l, r}) do
    with {:ok, ql} <- translate_predicate(l), {:ok, qr} <- translate_predicate(r) do
      {:ok, %{bool: %{must: [ql, qr]}}}
    end
  end

  defp translate_predicate({:or, l, r}) do
    with {:ok, ql} <- translate_predicate(l), {:ok, qr} <- translate_predicate(r) do
      {:ok, %{bool: %{should: [ql, qr], minimum_should_match: 1}}}
    end
  end

  defp translate_predicate({:not, p}) do
    with {:ok, qp} <- translate_predicate(p) do
      {:ok, %{bool: %{must_not: [qp]}}}
    end
  end

  # An ordinary `{:cmp, ...}`/`{:in, ...}` leaf -- see this module's
  # own moduledoc, "What's declined outright, and why."
  defp translate_predicate(_other),
    do: {:error, {:unsupported, {:construct, :non_search_predicate}}}

  # ---- ORDER BY -> sort ---------------------------------------------------

  defp translate_order_bys([]), do: {:ok, nil}

  defp translate_order_bys(order_bys) do
    order_bys
    |> Enum.reduce_while({:ok, []}, fn {key, direction}, {:ok, acc} ->
      case translate_order_item(key, direction) do
        {:ok, sort} -> {:cont, {:ok, acc ++ [sort]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, sorts} -> {:ok, sorts}
      :error -> {:error, {:unsupported, {:order_by, order_bys}}}
    end
  end

  defp translate_order_item({:call, "relevance", []}, direction) when direction in [:asc, :desc],
    do: {:ok, %{"_score" => sort_dir(direction)}}

  defp translate_order_item({:field, [field]}, direction)
       when direction in [:asc, :desc] and is_binary(field) do
    if identifier?(field), do: {:ok, %{field => sort_dir(direction)}}, else: :error
  end

  defp translate_order_item([field], direction)
       when direction in [:asc, :desc] and is_binary(field) do
    if identifier?(field), do: {:ok, %{field => sort_dir(direction)}}, else: :error
  end

  defp translate_order_item(_key, _direction), do: :error

  defp sort_dir(:asc), do: "asc"
  defp sort_dir(:desc), do: "desc"

  defp identifier?(field), do: is_binary(field) and Regex.match?(@identifier, field)

  # ---- relevance() rewrite (select only) ---------------------------------

  defp rewrite_relevance_body_item({:computed, alias_name, expr}),
    do: {:computed, alias_name, rewrite_relevance_expr(expr)}

  defp rewrite_relevance_body_item(other), do: other

  defp rewrite_relevance_expr({:call, "relevance", []}), do: {:field, [@relevance_field]}

  defp rewrite_relevance_expr({:call, name, args}),
    do: {:call, name, Enum.map(args, &rewrite_relevance_expr/1)}

  defp rewrite_relevance_expr({:arith, op, left, right}),
    do: {:arith, op, rewrite_relevance_expr(left), rewrite_relevance_expr(right)}

  defp rewrite_relevance_expr({:when, clauses, else_expr}) do
    rewritten_clauses =
      Enum.map(clauses, fn {predicate, expr} -> {predicate, rewrite_relevance_expr(expr)} end)

    {:when, rewritten_clauses, rewrite_relevance_expr(else_expr)}
  end

  defp rewrite_relevance_expr({:distinct, expr}), do: {:distinct, rewrite_relevance_expr(expr)}
  defp rewrite_relevance_expr({:dot, base, path}), do: {:dot, rewrite_relevance_expr(base), path}
  defp rewrite_relevance_expr(other), do: other

  @doc "The synthetic row field `relevance()` is rewritten to -- also used by `Scry.Engine.Elasticsearch` to populate it from each hit's own real `_score`."
  @spec relevance_field() :: String.t()
  def relevance_field, do: @relevance_field
end
