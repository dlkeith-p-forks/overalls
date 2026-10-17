defmodule Marshall.Accounts.Checks.ControlRoomRead do
  @moduledoc "Fresh Cedar authorization for read-only Control room projections."
  use Ash.Policy.SimpleCheck
  alias Marshall.Authorization.Cedar

  @impl true
  @spec describe(keyword()) :: String.t()
  def describe(_), do: "current Control room read authority"

  # @cc [owner:ghuntley,label:security] account-projection-read-only
  # This check MUST authorize only read projections; account mutations MUST use
  # the separate elevated administrator check, never admin_read.
  @impl true
  @spec match?(term(), map(), keyword()) :: boolean()
  def match?(actor, _, _),
    do: Cedar.allowed?(actor, "admin_read", Cedar.entity("ControlPlane", "marshall"))
end
