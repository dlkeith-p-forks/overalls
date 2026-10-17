defmodule OverallsProtocol.ProfilePolicy do
  @moduledoc "Closed profile capabilities shared by control-plane and host enforcement."
  @type capability :: :egress | :sharing | :web | :ssh | :terminal | :editor

  # @cc [owner:ghuntley,label:security] customer-closed-capabilities
  # Customer MUST permit only SSH, serial terminal and owner-authorized editor capabilities. Unknown profiles or
  # capabilities MUST fail closed. A capability never substitutes for owner authorization.
  @spec allows?(term(), term()) :: boolean()
  def allows?(:customer, capability), do: capability in [:ssh, :terminal, :editor]

  def allows?(profile, capability) when profile in [:standard, :oss, :inception],
    do: capability in [:egress, :sharing, :web, :ssh, :terminal, :editor]

  def allows?(_, _), do: false
end
