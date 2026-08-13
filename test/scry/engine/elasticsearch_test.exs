defmodule Scry.Engine.ElasticsearchTest do
  @moduledoc """
  `Scry.Engine.Elasticsearch` -- confirms `execute/3` translates
  `SEARCH`/`relevance()` into a real Elasticsearch Query DSL request
  and executes it against a real cluster, that `AND`/`OR`/`NOT`
  combinators compose correctly (including the `minimum_should_match`
  trap this package's own `QueryDsl` guards against explicitly), that
  `ORDER BY relevance() DESC`/a plain field/`LIMIT`/`OFFSET` all work,
  that an ordinary (non-`SEARCH`) `WHERE` comparison and `GROUP BY`/
  `HAVING`/`DISTINCT` all decline outright (no schema-level null-safety
  guarantee is possible against a real index, this package's own
  `QueryDsl` moduledoc has the full reasoning), and that an unknown
  index is a clear, tagged error rather than a crash -- all composing
  correctly end to end through a real `Scry.Core.Executor.run/4` call.

  **Requires a real, reachable Elasticsearch cluster** -- run one
  locally via `docker run -d -p 9200:9200 -e "discovery.type=single-node"
  -e "xpack.security.enabled=false" docker.elastic.co/elasticsearch/elasticsearch:8.15.0`.
  Runs `async: false` -- every test shares one real cluster and a
  small, fixed index, torn down and rebuilt in `setup_all`, rather than
  a fresh isolated database per test the way the embedded SQLite/DuckDB
  siblings get.

  A dedicated test for `execute/3`'s own `result_window_exceeded`
  guard (an unbounded query whose real match count exceeds what
  Elasticsearch actually returned) is deliberately not included here --
  reproducing it for real needs upwards of 10,000 indexed documents,
  prohibitively expensive for a fast test suite; the guard itself is
  documented and reasoned about directly in `Scry.Engine.Elasticsearch`'s
  own moduledoc instead.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.{Cursor, Executor, Query}
  alias Scry.Engine.Elasticsearch, as: Engine
  alias Scry.Engine.Elasticsearch.Conn

  @index "scry_test_products"

  setup_all do
    {:ok, conn} = Conn.open()

    Req.delete!("#{conn.base_url}/#{@index}")

    Req.put!("#{conn.base_url}/#{@index}",
      json: %{
        mappings: %{
          properties: %{
            name: %{type: "text"},
            description: %{type: "text"},
            price: %{type: "integer"},
            category: %{type: "keyword"}
          }
        }
      }
    )

    bulk_body =
      [
        %{
          name: "Wireless Mouse",
          description: "A wireless optical mouse, fully wireless, wireless USB receiver included",
          price: 25,
          category: "electronics"
        },
        %{
          name: "Wired Keyboard",
          description: "A mechanical wired keyboard",
          price: 45,
          category: "electronics"
        },
        %{
          name: "Coffee Mug",
          description: "A ceramic mug for coffee",
          price: 10,
          category: "kitchen"
        }
      ]
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {doc, id} -> [%{index: %{_id: to_string(id)}}, doc] end)
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> Kernel.<>("\n")

    Req.post!("#{conn.base_url}/#{@index}/_bulk",
      body: bulk_body,
      headers: [{"content-type", "application/x-ndjson"}]
    )

    Req.post!("#{conn.base_url}/#{@index}/_refresh")

    {:ok, conn: conn}
  end

  defp materialize({:ok, rows}), do: {:ok, rows |> Enum.to_list() |> Enum.sort_by(& &1["name"])}
  defp materialize(other), do: other

  describe "execute/3 -- SEARCH" do
    test "a match narrows to the right document", %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [{:variant, {:search, ["description"], "wireless"}}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Wireless Mouse"}]} =
               materialize(Engine.execute(conn, query, %{}))
    end

    test "no match at all returns zero rows", %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [{:variant, {:search, ["description"], "spaceship"}}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, []} = materialize(Engine.execute(conn, query, %{}))
    end

    test "relevance() in select returns a real Elasticsearch _score, not the toy reference scorer's count",
         %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [{:variant, {:search, ["description"], "wireless"}}],
        select: [{:field, ["name"]}, {:computed, "r", {:call, "relevance", []}}]
      }

      assert {:ok, [row]} = materialize(Engine.execute(conn, query, %{}))
      assert row["name"] == "Wireless Mouse"
      assert is_float(row["r"])
      assert row["r"] > 0
    end

    test "ORDER BY relevance() sorts by real score -- DESC and ASC are exact reverses of each other",
         %{conn: conn} do
      # Which of the two documents genuinely scores higher against real
      # BM25 is Elasticsearch's own business, not something this test
      # should hardcode a guess about -- the real, meaningful invariant
      # is that DESC and ASC order by the same real score, in opposite
      # directions, not a fixed name ordering.
      base = %Query{
        source: [@index],
        wheres: [
          {:or, {:variant, {:search, ["description"], "wireless"}},
           {:variant, {:search, ["description"], "mechanical"}}}
        ],
        select: [{:field, ["name"]}]
      }

      assert {:ok, desc_cursor} =
               Engine.execute(conn, %{base | order_bys: [{{:call, "relevance", []}, :desc}]}, %{})

      assert {:ok, asc_cursor} =
               Engine.execute(conn, %{base | order_bys: [{{:call, "relevance", []}, :asc}]}, %{})

      desc_names = desc_cursor |> Enum.to_list() |> Enum.map(& &1["name"])
      asc_names = asc_cursor |> Enum.to_list() |> Enum.map(& &1["name"])

      assert Enum.sort(desc_names) == Enum.sort(["Wired Keyboard", "Wireless Mouse"])
      assert desc_names == Enum.reverse(asc_names)
    end

    test "AND combines two SEARCH clauses -- both must match", %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [
          {:and, {:variant, {:search, ["description"], "wireless"}},
           {:variant, {:search, ["description"], "mouse"}}}
        ],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Wireless Mouse"}]} =
               materialize(Engine.execute(conn, query, %{}))
    end

    test "OR combines two SEARCH clauses -- either matches, real minimum_should_match: 1 set explicitly",
         %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [
          {:or, {:variant, {:search, ["description"], "wireless"}},
           {:variant, {:search, ["description"], "mechanical"}}}
        ],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["name"]) == ["Wired Keyboard", "Wireless Mouse"]
    end

    test "NOT excludes a matching SEARCH clause", %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [{:not, {:variant, {:search, ["description"], "wireless"}}}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["name"]) == ["Coffee Mug", "Wired Keyboard"]
    end

    test "a wildly nested AND/OR/NOT tree still composes correctly -- the minimum_should_match trap, exercised for real",
         %{conn: conn} do
      # (wireless OR mechanical) AND NOT (category-irrelevant kitchen match)
      query = %Query{
        source: [@index],
        wheres: [
          {:and,
           {:or, {:variant, {:search, ["description"], "wireless"}},
            {:variant, {:search, ["description"], "mechanical"}}},
           {:not, {:variant, {:search, ["description"], "ceramic"}}}}
        ],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.map(rows, & &1["name"]) == ["Wired Keyboard", "Wireless Mouse"]
    end
  end

  describe "execute/3 -- ORDER BY / LIMIT / OFFSET on ordinary fields" do
    test "a plain field ORDER BY works", %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [{:variant, {:search, ["category"], "electronics"}}],
        order_bys: [{["price"], :asc}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Engine.execute(conn, query, %{})
      names = cursor |> Enum.to_list() |> Enum.map(& &1["name"])
      assert names == ["Wireless Mouse", "Wired Keyboard"]
    end

    test "LIMIT + OFFSET compile to size/from and page correctly", %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [{:variant, {:search, ["category"], "electronics"}}],
        order_bys: [{["price"], :asc}],
        limit: 1,
        offset: 1,
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Engine.execute(conn, query, %{})
      assert cursor |> Enum.to_list() |> Enum.map(& &1["name"]) == ["Wired Keyboard"]
    end
  end

  describe "stated scope limits -- no schema-level null-safety guarantee exists in Elasticsearch" do
    test "an ordinary (non-SEARCH) WHERE comparison declines", %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [{:cmp, :gt, ["price"], 20}],
        select: [{:field, ["name"]}]
      }

      assert {:error, {:unsupported, {:construct, :non_search_predicate}}} =
               Engine.execute(conn, query, %{})
    end

    test "GROUP BY declines", %{conn: conn} do
      query = %Query{
        source: [@index],
        group_bys: [["category"]],
        select: [{:field, ["category"]}, {:computed, "n", {:call, "count", [{:field, ["name"]}]}}]
      }

      assert {:error, {:unsupported, {:construct, :group_by}}} = Engine.execute(conn, query, %{})
    end

    test "DISTINCT declines", %{conn: conn} do
      query = %Query{source: [@index], distinct: true, select: [{:field, ["category"]}]}
      assert {:error, {:unsupported, {:construct, :distinct}}} = Engine.execute(conn, query, %{})
    end

    test "SEARCH's own left-hand side must be a bare field path", %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [{:variant, {:search, {:call, "upper", []}, "wireless"}}],
        select: [{:field, ["name"]}]
      }

      assert {:error, {:unsupported, {:construct, :search_lhs_not_a_field}}} =
               Engine.execute(conn, query, %{})
    end
  end

  describe "an unknown index is a clear, tagged query_error, never a crash" do
    test "SEARCH against a nonexistent index", %{conn: conn} do
      query = %Query{
        source: ["ghost_index_xyz"],
        wheres: [{:variant, {:search, ["description"], "wireless"}}],
        select: [{:field, ["name"]}]
      }

      assert {:error, {:query_error, _}} = Engine.execute(conn, query, %{})
    end

    test "a source that isn't a safe identifier is rejected before ever touching HTTP", %{
      conn: conn
    } do
      malicious = ["../_all"]
      query = %Query{source: malicious, select: []}

      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:source, hd(malicious)}}}
    end
  end

  describe "end to end through Scry.Core.Executor.run/4" do
    test "a SEARCH query executes correctly through the full pipeline", %{conn: conn} do
      query = %Query{
        source: [@index],
        wheres: [{:variant, {:search, ["description"], "wireless"}}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)
      assert Cursor.to_list(cursor) == [%{"name" => "Wireless Mouse"}]
    end
  end

  describe "execute/3 -- delegated to Scry.Core.QueryOps.run_document/4" do
    test "a WITH-bound source is delegated and produces correct results", %{conn: conn} do
      query = %Query{
        source: ["cheap_electronics"],
        select: [{:field, ["name"]}],
        with_bindings: %{
          "cheap_electronics" => %Query{
            source: [@index],
            wheres: [{:variant, {:search, ["category"], "electronics"}}],
            order_bys: [{["price"], :asc}],
            select: [{:field, ["name"]}]
          }
        }
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)

      assert Cursor.to_list(cursor) == [
               %{"name" => "Wireless Mouse"},
               %{"name" => "Wired Keyboard"}
             ]
    end
  end

  describe "describe_source/2 (Scry.Core.EngineBehaviour's optional callback)" do
    test "converts a real index mapping into introspected_field()s, always nullable: true", %{
      conn: conn
    } do
      assert {:ok, fields} = Engine.describe_source(conn, @index)
      by_name = Map.new(fields, &{&1.name, &1})

      assert by_name["name"] == %{name: "name", nullable: true, scalar: :string}
      assert by_name["price"] == %{name: "price", nullable: true, scalar: :integer}
      assert by_name["category"] == %{name: "category", nullable: true, scalar: :string}
    end

    test "an unknown index is {:error, :not_found}", %{conn: conn} do
      assert Engine.describe_source(conn, "ghost_index_xyz") == {:error, :not_found}
    end
  end
end
