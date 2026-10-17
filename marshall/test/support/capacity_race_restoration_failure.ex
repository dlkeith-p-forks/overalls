defmodule Marshall.Compute.CapacityRaceRestorationFailure do
  @moduledoc false
  alias Marshall.CommittedFixtureCleanup, as: Cleanup

  @type t(value) :: %__MODULE__{
          action_result: value,
          cleanup_failure: Cleanup.failure(),
          message: String.t()
        }
  defexception [
    :action_result,
    :cleanup_failure,
    message: "capacity race connection restoration failed after action returned"
  ]
end
