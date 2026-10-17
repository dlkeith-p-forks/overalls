defmodule ZiggyInferenceAuthorityContractTest do
  use Covenant.Case, component: "ziggy.inference_authority"

  @tag obligation: "ziggy.inference_authority.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Ziggy.Control,
      Ziggy.Control.Link,
      Ziggy.Credential,
      Ziggy.HTTP,
      Ziggy.Lease,
      Ziggy.Route,
      Ziggy.Upstream
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
