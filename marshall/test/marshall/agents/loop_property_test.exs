defmodule Marshall.Agents.LoopPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "context wait diagnostics are emitted only at the initial and 15-second boundaries",
    test_cases: 100 do
    check all(seconds <- integer(0..600)) do
      expected = seconds == 0 or rem(seconds, 15) == 0
      assert Marshall.Agents.Loop.context_wait_event?(seconds) == expected
    end
  end
end
