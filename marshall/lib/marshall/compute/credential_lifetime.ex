defmodule Marshall.Compute.CredentialLifetime do
  @moduledoc "Credential lifetime policy, in fixed seconds (five 365-day years)."
  @maximum 157_680_000

  # @cc [owner:ghuntley,label:security] credential-lifetime-boundary
  # All issuance entry points MUST accept only integer lifetimes from one second
  # through five 365-day years. Existing expiry timestamps MUST NOT be extended.
  defguard valid(lifetime) when is_integer(lifetime) and lifetime in 1..@maximum

  @spec maximum() :: pos_integer()
  def maximum, do: @maximum
end
