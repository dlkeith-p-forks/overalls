defmodule Galileo.Counter do
  @moduledoc "Persistent opaque counters for bounded numeric operational gauges."
  @key {__MODULE__, :counters}

  # @cc [owner:ghuntley,label:security] galileo-counters-numeric-only
  # Counters MUST hold bounded request counts only; no identity, content or
  # credential may influence or be derivable from them.
  @spec counters() :: :counters.counters_ref()
  def counters do
    case :persistent_term.get(@key, nil) do
      nil ->
        ref = :counters.new(2, [:write_concurrency])
        :persistent_term.put(@key, ref)
        ref

      ref ->
        ref
    end
  end
end
