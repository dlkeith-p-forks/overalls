defmodule Marshall.Notifications.Retry do
  @moduledoc "Pure retry mapping and jittered backoff for Susan deliveries (ADR-0225)."

  @type outcome ::
          Marshall.Notifications.Susan.outcome()
          | {:unsealable, :request_too_large | :unsealable}
  @type decision ::
          :delivered
          | :invalidate
          | {:permanent, atom()}
          | {:retry, atom(), non_neg_integer() | nil}

  @base 2
  @cap 300

  # @cc [owner:ghuntley,label:recovery] notification-retry-mapping
  # 2xx MUST deliver; 404 and 410 MUST invalidate the device and drop the
  # delivery; 429, 5xx, transport and timeout failures MUST retry (honouring a
  # bounded Retry-After) until the final attempt, which is permanent as
  # exhausted; every other status and any unsealable poke is permanent.
  @doc "Classifies one attempt's outcome. `final?` is true on the last Oban attempt."
  @spec decide(outcome(), boolean()) :: decision()
  def decide({:ok, _status}, _final?), do: :delivered
  def decide({:invalidated, _status}, _final?), do: :invalidate
  def decide({:rejected, _status}, _final?), do: {:permanent, :rejected}
  def decide({:unsealable, reason}, _final?), do: {:permanent, reason}
  def decide({:retry, _reason, _status, _after}, true), do: {:permanent, :exhausted}
  def decide({:retry, reason, _status, retry_after}, false), do: {:retry, reason, retry_after}

  @doc "Exponential backoff with full jitter in seconds, for 1-based attempts and `jitter` in [0, 1]."
  @spec backoff(pos_integer(), float()) :: pos_integer()
  def backoff(attempt, jitter)
      when is_integer(attempt) and attempt >= 1 and is_float(jitter) and jitter >= 0.0 and
             jitter <= 1.0 do
    ceiling = min(@cap, @base * Integer.pow(2, min(attempt - 1, 16)))
    max(1, round(ceiling / 2 + ceiling / 2 * jitter))
  end

  @doc "Upper bound of the backoff for any attempt, in seconds."
  @spec cap() :: pos_integer()
  def cap, do: @cap
end
