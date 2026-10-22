defmodule Marshall.Threads.ProvisionWorkerPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "only transient activation failures are retried", test_cases: 100 do
    check all(
            reason <- one_of([constant(:machine_not_ready), constant(:agent_unavailable), atom()])
          ) do
      assert Marshall.Threads.ProvisionWorker.retryable_activation_reason?(reason) ==
               reason in [:machine_not_ready, :agent_unavailable]
    end
  end
end
