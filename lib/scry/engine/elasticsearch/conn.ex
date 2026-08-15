defmodule Scry.Engine.Elasticsearch.Conn do
  @moduledoc """
  Wraps the base URL of a reachable Elasticsearch cluster -- no actual
  connection exists to open at all, unlike every other adapter in this
  family: Elasticsearch's own REST API is plain, stateless JSON-over-
  HTTP, so `open/1` performs no I/O and there is no persistent resource
  for a `close/1` to release (`req`'s own connection pooling, via
  `Finch`, is managed transparently underneath every individual
  request instead). `open/1` still exists, and still returns `{:ok,
  t()}`, purely to match the connection/config-struct shape every real
  adapter in this ecosystem exposes -- a caller
  writing generic code against multiple engines shouldn't need to know
  which ones happen to need real setup and which don't.
  """

  @type t :: %__MODULE__{base_url: String.t()}

  @enforce_keys [:base_url]
  defstruct [:base_url]

  @default_base_url "http://localhost:9200"

  @doc """
  Wraps `base_url` (default `"http://localhost:9200"`, a stock local
  Elasticsearch container with security disabled).
  """
  @spec open(String.t()) :: {:ok, t()}
  def open(base_url \\ @default_base_url) when is_binary(base_url) do
    {:ok, %__MODULE__{base_url: String.trim_trailing(base_url, "/")}}
  end
end
