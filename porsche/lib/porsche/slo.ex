defmodule Porsche.SLO do
  @moduledoc "Fixed cumulative terminal SSH command dispatch outcomes."
  alias Overalls.RequestAccounting.Aggregate

  @type t :: Aggregate.t()
  @type snapshot :: Aggregate.snapshot()

  @spec new() :: t()
  def new, do: Aggregate.new("porsche")

  # @cc [owner:ghuntley,label:reliability;security] porsche-terminal-dispatch-once
  # Each observed terminal SSH command dispatch MUST add one outcome and duration
  # bucket. Commands, sessions, receipts and account identities MUST NOT enter labels.
  @spec record(t(), boolean(), non_neg_integer()) :: t()
  def record(state, success, duration_us)
      when is_boolean(success) and is_integer(duration_us) and duration_us >= 0 do
    Aggregate.record(state, if(success, do: :success, else: :failure), duration_us)
  end

  @doc "The fixed histogram slot for a measured terminal dispatch duration."
  @spec bucket_index(non_neg_integer()) :: 0..7
  def bucket_index(duration_us), do: Aggregate.bucket_index(duration_us)

  @spec snapshot(t()) :: snapshot()
  def snapshot(state), do: Aggregate.snapshot(state)
end
