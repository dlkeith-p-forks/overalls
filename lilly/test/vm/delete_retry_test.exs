defmodule Lilly.VM.DeleteRetryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.VM.DeleteRetry

  # @cc [owner:ghuntley,label:verification] delete-retry-bounded-and-monotonic
  # All positive attempt counts MUST produce a positive delay no greater than
  # thirty seconds, and repeated failures MUST never reduce that delay.
  property "delete retries grow monotonically and remain bounded" do
    check all(attempt <- integer(1..100_000)) do
      current = DeleteRetry.delay(attempt)
      following = DeleteRetry.delay(attempt + 1)
      assert current in 1000..30_000
      assert following >= current
    end
  end

  test "early retries leave a window for mount teardown" do
    assert Enum.map(1..7, &DeleteRetry.delay/1) ==
             [1000, 2000, 4000, 8000, 16_000, 30_000, 30_000]
  end
end
