defmodule Scry.Engine.Elasticsearch.QueryDslTest do
  use ExUnit.Case, async: true

  alias Scry.Core.Query
  alias Scry.Engine.Elasticsearch.QueryDsl

  describe "compile/1 -- WHERE translation" do
    test "no wheres compiles to match_all" do
      query = %Query{source: ["t"], select: [{:field, ["name"]}]}
      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.query == %{match_all: %{}}
    end

    test "a single SEARCH clause compiles to a bare match query, no extra bool.must wrapper" do
      query = %Query{
        source: ["t"],
        wheres: [{:variant, {:search, ["description"], "wireless"}}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.query == %{match: %{"description" => "wireless"}}
    end

    test "a multi-segment field path joins with a dot" do
      query = %Query{
        source: ["t"],
        wheres: [{:variant, {:search, ["a", "b"], "x"}}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.query == %{match: %{"a.b" => "x"}}
    end

    test "AND compiles to bool.must, no extra outer wrapper for the single top-level predicate" do
      query = %Query{
        source: ["t"],
        wheres: [
          {:and, {:variant, {:search, ["a"], "x"}}, {:variant, {:search, ["b"], "y"}}}
        ],
        select: [{:field, ["name"]}]
      }

      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.query == %{bool: %{must: [%{match: %{"a" => "x"}}, %{match: %{"b" => "y"}}]}}
    end

    test "OR compiles to bool.should with minimum_should_match: 1 set explicitly -- no extra outer wrapper, the real fix for a confirmed scoring-tie quirk that wrapper caused" do
      query = %Query{
        source: ["t"],
        wheres: [
          {:or, {:variant, {:search, ["a"], "x"}}, {:variant, {:search, ["b"], "y"}}}
        ],
        select: [{:field, ["name"]}]
      }

      assert {:ok, %{body: body}} = QueryDsl.compile(query)

      assert body.query == %{
               bool: %{
                 should: [%{match: %{"a" => "x"}}, %{match: %{"b" => "y"}}],
                 minimum_should_match: 1
               }
             }
    end

    test "NOT compiles to bool.must_not, no extra outer wrapper" do
      query = %Query{
        source: ["t"],
        wheres: [{:not, {:variant, {:search, ["a"], "x"}}}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.query == %{bool: %{must_not: [%{match: %{"a" => "x"}}]}}
    end

    test "two top-level wheres entries (an implicit AND) still get the real bool.must wrapper" do
      query = %Query{
        source: ["t"],
        wheres: [
          {:variant, {:search, ["a"], "x"}},
          {:variant, {:search, ["b"], "y"}}
        ],
        select: [{:field, ["name"]}]
      }

      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.query == %{bool: %{must: [%{match: %{"a" => "x"}}, %{match: %{"b" => "y"}}]}}
    end

    test "an ordinary :cmp predicate leaf declines" do
      query = %Query{source: ["t"], wheres: [{:cmp, :eq, ["a"], 1}], select: [{:field, ["name"]}]}

      assert QueryDsl.compile(query) ==
               {:error, {:unsupported, {:construct, :non_search_predicate}}}
    end

    test "a SEARCH left-hand side that isn't a bare field path declines" do
      query = %Query{
        source: ["t"],
        wheres: [{:variant, {:search, {:call, "upper", []}, "x"}}],
        select: [{:field, ["name"]}]
      }

      assert QueryDsl.compile(query) ==
               {:error, {:unsupported, {:construct, :search_lhs_not_a_field}}}
    end
  end

  describe "compile/1 -- ORDER BY / LIMIT / OFFSET" do
    test "relevance() DESC compiles to _score sort, with track_scores set" do
      query = %Query{
        source: ["t"],
        order_bys: [{{:call, "relevance", []}, :desc}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.sort == [%{"_score" => "desc"}]
      assert body.track_scores == true
    end

    test "a plain field ASC compiles to an ordinary sort entry" do
      query = %Query{source: ["t"], order_bys: [{["price"], :asc}], select: [{:field, ["name"]}]}

      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.sort == [%{"price" => "asc"}]
    end

    test "no order_bys omits sort/track_scores entirely" do
      query = %Query{source: ["t"], select: [{:field, ["name"]}]}
      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      refute Map.has_key?(body, :sort)
      refute Map.has_key?(body, :track_scores)
    end

    test "limit/offset compile to size/from" do
      query = %Query{source: ["t"], limit: 5, offset: 10, select: [{:field, ["name"]}]}
      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.size == 5
      assert body.from == 10
    end

    test "no limit defaults size to Elasticsearch's own max_result_window (10_000), from defaults to 0" do
      query = %Query{source: ["t"], select: [{:field, ["name"]}]}
      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.size == 10_000
      assert body.from == 0
    end

    test "track_total_hits is always set" do
      query = %Query{source: ["t"], select: [{:field, ["name"]}]}
      assert {:ok, %{body: body}} = QueryDsl.compile(query)
      assert body.track_total_hits == true
    end
  end

  describe "compile/1 -- relevance() rewrite in select" do
    test "relevance() is rewritten to an ordinary field reference against the synthetic relevance field" do
      query = %Query{
        source: ["t"],
        select: [{:field, ["name"]}, {:computed, "r", {:call, "relevance", []}}]
      }

      assert {:ok, %{query: rewritten}} = QueryDsl.compile(query)

      assert rewritten.select == [
               {:field, ["name"]},
               {:computed, "r", {:field, [QueryDsl.relevance_field()]}}
             ]
    end

    test "relevance() nested inside arithmetic still rewrites" do
      query = %Query{
        source: ["t"],
        select: [{:computed, "boosted", {:arith, :*, {:call, "relevance", []}, 2}}]
      }

      assert {:ok, %{query: rewritten}} = QueryDsl.compile(query)

      assert rewritten.select == [
               {:computed, "boosted", {:arith, :*, {:field, [QueryDsl.relevance_field()]}, 2}}
             ]
    end
  end

  describe "compile/1 -- declined constructs" do
    test "GROUP BY declines" do
      query = %Query{source: ["t"], group_bys: [["a"]], select: [{:field, ["a"]}]}

      assert QueryDsl.compile(query) == {:error, {:unsupported, {:construct, :group_by}}}
    end

    test "an aggregate call in select declines even with no explicit group_bys" do
      query = %Query{
        source: ["t"],
        select: [{:computed, "n", {:call, "count", [{:field, ["a"]}]}}]
      }

      assert QueryDsl.compile(query) == {:error, {:unsupported, {:construct, :group_by}}}
    end

    test "HAVING declines" do
      query = %Query{source: ["t"], havings: [{:cmp, :gt, ["n"], 1}], select: [{:field, ["a"]}]}
      assert QueryDsl.compile(query) == {:error, {:unsupported, {:construct, :having}}}
    end

    test "DISTINCT declines" do
      query = %Query{source: ["t"], distinct: true, select: [{:field, ["a"]}]}
      assert QueryDsl.compile(query) == {:error, {:unsupported, {:construct, :distinct}}}
    end
  end
end
