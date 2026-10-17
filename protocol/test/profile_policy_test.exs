defmodule OverallsProtocol.ProfilePolicyTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.ProfilePolicy

  property "customer capabilities form a closed set",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 761_162_639 do
    capability =
      draw(
        "capability",
        one_of([
          member_of([:ssh, :terminal, :editor, :web, :sharing, :egress]),
          OverallsProtocol.TestGenerators.peer_term()
        ])
      )

    assert ProfilePolicy.allows?(:customer, capability) ==
             capability in [:ssh, :terminal, :editor]
  end

  property "unknown profiles cannot obtain any capability",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 199_747_403 do
    profile = draw("profile", OverallsProtocol.TestGenerators.peer_term())
    Hegel.assume(profile not in [:customer, :standard, :oss, :inception])

    capability =
      draw("capability", member_of([:ssh, :terminal, :editor, :web, :sharing, :egress]))

    refute ProfilePolicy.allows?(profile, capability)
  end

  test "other declared profiles retain their capabilities" do
    for profile <- [:standard, :oss, :inception],
        capability <- [:ssh, :terminal, :editor, :web, :sharing, :egress] do
      assert ProfilePolicy.allows?(profile, capability)
    end
  end
end
