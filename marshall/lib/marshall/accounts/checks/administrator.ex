defmodule Marshall.Accounts.Checks.Administrator do
  @moduledoc "Fresh Cedar authorization for administrative account actions."
  use Ash.Policy.SimpleCheck
  alias Marshall.Authorization.Cedar

  @impl true
  @spec describe(keyword()) :: String.t()
  def describe(_), do: "current administrator account authority"

  # @cc [owner:ghuntley,label:security] account-mutation-authority
  # Account mutations MUST require current Cedar admin_accounts permission,
  # including persisted administrator membership and recent passkey elevation.
  @impl true
  @spec match?(term(), map(), keyword()) :: boolean()
  def match?(actor, _, _),
    do: Cedar.allowed?(actor, "admin_accounts", Cedar.entity("ControlPlane", "marshall"))
end
