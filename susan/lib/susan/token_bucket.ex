defmodule Susan.TokenBucket do
  @moduledoc """
  Pure token-bucket arithmetic in integer milli-tokens.

  A bucket holds at most `burst` tokens and refills `per_hour` tokens per
  hour. Time is integer milliseconds supplied by the caller, so the model is
  deterministic and property-testable; a clock that goes backwards never adds
  tokens.
  """

  @enforce_keys [:level, :at, :limited]
  defstruct [:level, :at, :limited]

  @scale 1000
  @hour_ms 3_600_000

  @type limit :: %{burst: pos_integer(), per_hour: pos_integer()}
  @type t :: %__MODULE__{level: non_neg_integer(), at: integer(), limited: boolean()}
  @type result ::
          {:ok, t()}
          | {:error, retry_after_seconds :: pos_integer(), first_refusal :: boolean(), t()}

  @spec new(limit(), integer()) :: t()
  def new(%{burst: burst}, now_ms),
    do: %__MODULE__{level: burst * @scale, at: now_ms, limited: false}

  # @cc [owner:ghuntley,label:capacity;security] susan-token-bucket-bounds
  # A bucket MUST never exceed its burst, never go negative, never refill when
  # time does not advance, and MUST admit at most burst + elapsed*rate tokens
  # over any interval. A refusal MUST report a positive Retry-After that is
  # sufficient for one token to refill.
  @spec take(t() | nil, limit(), integer()) :: result()
  def take(nil, limit, now_ms), do: take(new(limit, now_ms), limit, now_ms)

  def take(%__MODULE__{} = bucket, %{burst: burst, per_hour: per_hour}, now_ms) do
    elapsed = max(now_ms - bucket.at, 0)
    refill = div(elapsed * per_hour * @scale, @hour_ms)
    level = min(bucket.level + refill, burst * @scale)
    # Advance the reference time only by the time actually converted into
    # whole milli-tokens, so sub-unit refill is never lost to rounding.
    at =
      if level == burst * @scale,
        do: max(now_ms, bucket.at),
        else: bucket.at + div(refill * @hour_ms, per_hour * @scale)

    if level >= @scale do
      {:ok, %__MODULE__{level: level - @scale, at: at, limited: false}}
    else
      missing = @scale - level
      retry_ms = div(missing * @hour_ms + per_hour * @scale - 1, per_hour * @scale)
      retry = max(div(retry_ms + 999, 1000), 1)
      {:error, retry, not bucket.limited, %__MODULE__{level: level, at: at, limited: true}}
    end
  end

  @doc "Whether the bucket has refilled to its burst, so it equals a fresh bucket."
  @spec full?(t(), limit(), integer()) :: boolean()
  def full?(%__MODULE__{} = bucket, %{burst: burst, per_hour: per_hour}, now_ms) do
    elapsed = max(now_ms - bucket.at, 0)
    bucket.level + div(elapsed * per_hour * @scale, @hour_ms) >= burst * @scale
  end
end
