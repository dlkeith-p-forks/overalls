defmodule Ziggy.SLO do
  @moduledoc "Fixed cumulative outcomes for durably completed inference admissions."
  alias Overalls.RequestAccounting.Aggregate

  @max_duration_ms div(Aggregate.max_counter(), 1_000)

  @type t :: Aggregate.t()
  @type snapshot :: Aggregate.snapshot()

  @spec new() :: t()
  def new, do: Aggregate.new("ziggy")

  # @cc [owner:ghuntley,label:reliability;security] ziggy-completed-admission-once
  # Each newly durable terminal completion MUST add one fixed outcome, except
  # caller-cancelled streams. Missing duration MUST remain unknown, never zero.
  # Request, VM, owner, provider, model and payload data MUST NOT become labels.
  @spec record(t(), map()) :: t()
  def record(state, %{"outcome" => "cancelled"}), do: Aggregate.record(state, :exclude, nil)

  def record(state, completion) do
    success = completion["outcome"] == "completed" and completion["http_status"] in 200..299

    case completion["duration_ms"] do
      duration_ms when is_integer(duration_ms) and duration_ms in 0..@max_duration_ms ->
        duration_us = duration_ms * 1000
        Aggregate.record(state, if(success, do: :success, else: :failure), duration_us)

      _ ->
        Aggregate.record(state, if(success, do: :success, else: :failure), nil)
    end
  end

  @spec snapshot(t()) :: snapshot()
  def snapshot(state), do: Aggregate.snapshot(state)
end
