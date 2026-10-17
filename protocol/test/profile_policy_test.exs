defmodule OverallsProtocol.ProfilePolicyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.ProfilePolicy

  property "customer capabilities form a closed set" do
    check all(
            capability <-
              one_of([member_of([:ssh, :terminal, :editor, :web, :sharing, :egress]), term()])
          ) do
      assert ProfilePolicy.allows?(:customer, capability) ==
               capability in [:ssh, :terminal, :editor]
    end
  end

  property "unknown profiles cannot obtain any capability" do
    check all(
            profile <- term(),
            profile not in [:customer, :standard, :oss, :inception],
            capability <- member_of([:ssh, :terminal, :editor, :web, :sharing, :egress])
          ) do
      refute ProfilePolicy.allows?(profile, capability)
    end
  end

  test "other declared profiles retain their capabilities" do
    for profile <- [:standard, :oss, :inception],
        capability <- [:ssh, :terminal, :editor, :web, :sharing, :egress] do
      assert ProfilePolicy.allows?(profile, capability)
    end
  end
end
