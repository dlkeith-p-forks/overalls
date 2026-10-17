defmodule Lilly.Control.RuntimeBackoffTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # @cc [owner:ghuntley,label:verification;recovery] control-backoff-bounded-property
  # Every failure count MUST yield a delay that starts at one second, never
  # decreases, and never exceeds the four-second cap.
  property "control backoff starts at one second, grows, and stays within four seconds" do
    assert Lilly.Control.Runtime.retry_delay(1) == 1_000

    check all(failures <- integer(1..1_000)) do
      delay = Lilly.Control.Runtime.retry_delay(failures)
      assert delay in 1_000..4_000
      assert delay <= Lilly.Control.Runtime.retry_delay(failures + 1)
    end
  end
end
