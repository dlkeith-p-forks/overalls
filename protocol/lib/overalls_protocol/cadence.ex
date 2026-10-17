defmodule OverallsProtocol.Cadence do
  @moduledoc """
  Single-flight periodic work that always rests between periodic runs.

  The owner sends `:tick` from its timer, `:request` when an event (a new
  command, superseded work) needs a run, and `:done` when the run it started
  finishes; it executes the returned `:start` effects.

  A periodic tick during a run is dropped: the next tick starts the next run,
  so periodic work always leaves an idle gap. Back-to-back periodic runs under
  load would otherwise hold shared locks (the pool lock, the placement lock)
  almost continuously and starve mutations that try them without waiting.
  A request during a run is remembered once and starts the next run as soon
  as the current one finishes; further requests collapse into it.
  """
  use OverallsProtocol.Machine,
    initial: :idle,
    edges: [
      idle: [tick: :running, request: :running],
      running: [tick: :running, request: :running_due, done: :idle],
      running_due: [tick: :running_due, request: :running_due, done: :running]
    ]

  @enforce_keys [:state]
  defstruct [:state]

  @type t :: %__MODULE__{state: :idle | :running | :running_due}
  @type event :: :tick | :request | :done
  @type effect :: :start

  @doc "A cadence with nothing in flight."
  @spec new() :: t()
  def new, do: %__MODULE__{state: initial()}

  # @cc [owner:ghuntley,label:capacity;recovery;concurrency] cadence-single-flight-rest
  # step/2 MUST start at most one run at a time. A tick while idle starts a
  # run; a tick during a run MUST NOT start or schedule one, so periodic runs
  # are never back to back. A request during a run MUST start exactly one
  # follow-up on completion, collapsing repeated requests, so events are never
  # lost and slow work never builds a backlog. A `:done` without a run in
  # flight is an invalid transition, never a start.
  @spec step(t(), event()) :: {:ok, t(), [effect()]} | {:error, :invalid_transition}
  def step(%__MODULE__{state: state} = cadence, event) when event in [:tick, :request, :done] do
    with {:ok, next} <- target(state, event) do
      {:ok, %{cadence | state: next}, effects(state, next)}
    end
  end

  def step(%__MODULE__{}, _event), do: {:error, :invalid_transition}

  @doc "Whether a run is in flight."
  @spec running?(t()) :: boolean()
  def running?(%__MODULE__{state: state}), do: state != :idle

  defp effects(:idle, :running), do: [:start]
  defp effects(:running_due, :running), do: [:start]
  defp effects(_from, _to), do: []
end
