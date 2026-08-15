# scry_engine_elasticsearch

A real [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation over [Elasticsearch](https://www.elastic.co/elasticsearch),
replacing [`scry_search`](https://github.com/joetjen/scry_search)'s own
reference implementation (`Scry.Search.Executor` -- a toy token-overlap
relevance scorer, explicitly documented there as "proving the language
construct executes, not an integration with any real search engine")
with genuine `SEARCH`/`relevance()` execution against a real full-text
search engine. Closes the validation the roadmap already calls for:
Elasticsearch is `search`'s own namesake reference language, needing
direct validation, "not just a RedisSearch stand-in."

Source: <https://github.com/joetjen/scry_engine_elasticsearch>. The
behaviour this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
{:ok, conn} = Scry.Engine.Elasticsearch.Conn.open("http://localhost:9200")

{:ok, query} = Scry.Core.parse(~s(SELECT products WHERE description SEARCH "wireless" { name }))
{:ok, cursor} = Scry.Core.Executor.run(query, Scry.Engine.Elasticsearch, conn)
rows = Scry.Core.Cursor.to_list(cursor)
# rows == [%{"name" => "Wireless Mouse"}]
```

`Conn.open/1` performs no I/O -- Elasticsearch's own REST API is plain,
stateless JSON-over-HTTP, so there's no real connection to open or
close; the struct exists purely to match the connection/config shape
every adapter in this ecosystem exposes.

### Local development / running the test suite

```sh
docker run -d -p 9200:9200 \
  -e "discovery.type=single-node" \
  -e "xpack.security.enabled=false" \
  docker.elastic.co/elasticsearch/elasticsearch:8.15.0
```

## Scope: `SEARCH`/`relevance()` only -- not a general Elasticsearch-as-relational-store adapter

Every one of `GROUP BY`/aggregates/`HAVING`/`DISTINCT`, and an
ordinary (non-`SEARCH`) `WHERE` comparison, depends on the same
schema-level `NOT NULL` guarantee `scry_engine_exqlite`/
`scry_engine_duckdbex`/`scry_engine_myxql` all verify before trusting
one. **Elasticsearch has no equivalent to verify against at all** --
confirmed directly: an index mapping declares a field's own *type*,
never a presence/required guarantee, and any document can omit any
field with no schema violation whatsoever. Rather than accept that
gap silently, this package declines every construct that would need
it, supporting exactly what it exists to validate: `SEARCH`/
`relevance()`, ordinary field projection, `ORDER BY` (a bare field or
`relevance()`), and `LIMIT`/`OFFSET`.

## A real pagination-safety concern this package guards against

Elasticsearch's own default `size` is `10`, and `hits.total` is
itself only a lower-bound estimate past 10,000 matches unless
`track_total_hits: true` is set (confirmed directly). This package
always sets an explicit `size` (`query.limit`, or `10_000` --
Elasticsearch's own default `index.max_result_window` cap -- when no
`limit` was given) and always tracks the real total hit count;
`execute/3` compares the two and declines with `{:query_error,
{:result_window_exceeded, total}}` rather than silently handing back
a truncated page when a caller wrote no explicit `LIMIT` but the real
match count exceeds what was returned.

## A real, confirmed Elasticsearch scoring quirk found building this

Wrapping a single top-level predicate in an extra `bool.must: [...]`
layer is semantically a no-op for *matching* -- still exactly the same
documents -- but a real, confirmed scoring quirk when the one wrapped
clause is itself a `bool.should`: two documents that score genuinely
differently unwrapped came back with *identical* `_score` values once
wrapped, silently turning `ORDER BY relevance()` into a tie broken by
an arbitrary, direction-independent order instead of the real score.
`Scry.Engine.Elasticsearch.QueryDsl` never adds that wrapper for a
single top-level predicate.

## Installation

```elixir
def deps do
  [
    {:scry_engine_elasticsearch, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_elasticsearch>.
