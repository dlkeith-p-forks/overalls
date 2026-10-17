defmodule Enrico.SLO do
  @moduledoc "Fixed cumulative outcomes for admitted mirror refresh attempts."
  alias Overalls.RequestAccounting.Aggregate

  @type t :: Aggregate.t()
  @type snapshot :: Aggregate.snapshot()

  @spec new() :: t()
  def new, do: Aggregate.new("enrico")

  # @cc [owner:ghuntley,label:reliability;security] enrico-terminal-attempt-once
  # Each admitted terminal attempt MUST add exactly one outcome and duration
  # bucket. Repository IDs, owners, refs and paths MUST NOT become labels.
  @spec record(t(), boolean(), non_neg_integer()) :: t()
  def record(state, success, duration_us)
      when is_boolean(success) and is_integer(duration_us) and duration_us >= 0 do
    Aggregate.record(state, if(success, do: :success, else: :failure), duration_us)
  end

  @spec snapshot(t()) :: snapshot()
  def snapshot(state), do: Aggregate.snapshot(state)
end
