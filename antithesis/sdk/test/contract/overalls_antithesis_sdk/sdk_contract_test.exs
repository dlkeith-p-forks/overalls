defmodule OverallsAntithesisSdkSdkContractTest do
  use Covenant.Case, component: "overalls_antithesis_sdk.sdk"

  @tag obligation: "overalls_antithesis_sdk.sdk.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      OverallsAntithesis.SDK,
      OverallsAntithesis.SDK.Application,
      OverallsAntithesis.SDK.Details,
      OverallsAntithesis.SDK.Property,
      OverallsAntithesis.SDK.Writer
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
