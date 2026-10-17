defmodule Ziggy.VersionFence do
  @moduledoc """
  A recoverable control-API version fence (ADR-0140 phase 8).

  An HTTP 426 from Marshall means this Ziggy speaks a version Marshall will not
  accept. During a rolling deploy that can be transient, so instead of stopping
  until restart the caller backs off: only its own tagged probe may make the
  next request, after 30 seconds and then doubling to ten minutes. Any
  accepted request reopens the fence. Nothing is retried at the normal cadence
  while fenced, and stray scheduling messages are ignored.
  """

  @initial_ms 30_000
  @maximum_ms 600_000

  @enforce_keys [:initial]
  defstruct [:initial, backoff: nil, token: nil]

  @type t :: %__MODULE__{
          initial: pos_integer(),
          backoff: pos_integer() | nil,
          token: reference() | nil
        }

  @spec new(keyword()) :: t()
  def new(options \\ []),
    do: %__MODULE__{initial: Keyword.get(options, :fence_backoff_ms, @initial_ms)}

  @spec fenced?(t()) :: boolean()
  def fenced?(%__MODULE__{backoff: backoff}), do: backoff != nil

  # @cc [owner:ghuntley,label:recovery] ziggy-version-fence-recoverable
  # A version refusal MUST fence normal-cadence requests and schedule exactly
  # one tagged probe after an exponential backoff (initial, doubling, capped at
  # ten minutes). Only that probe's token may run while fenced. An accepted
  # request MUST clear the fence.
  @doc "Records a refusal; returns the fence, the probe delay and its token."
  @spec refused(t()) :: {t(), pos_integer(), reference()}
  def refused(%__MODULE__{backoff: backoff, initial: initial} = fence) do
    delay = if backoff, do: min(backoff * 2, max(@maximum_ms, initial)), else: initial
    token = make_ref()
    {%{fence | backoff: delay, token: token}, delay, token}
  end

  @spec accepted(t()) :: t()
  def accepted(fence), do: %{fence | backoff: nil, token: nil}

  @doc "Whether `token` is the fence's current probe."
  @spec probe?(t(), term()) :: boolean()
  def probe?(%__MODULE__{token: token}, candidate), do: token != nil and token == candidate
end
