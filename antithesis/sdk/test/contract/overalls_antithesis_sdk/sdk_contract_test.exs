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

  @tag obligation: "overalls_antithesis_sdk.sdk.I2"
  test "details reject negative and oversized values and wire only present fields" do
    valid = %OverallsAntithesis.SDK.Details{accepted_count: 2, elapsed_ms: 10}
    assert OverallsAntithesis.SDK.Details.valid?(valid)

    assert %{"accepted_count" => 2, "elapsed_ms" => 10} =
             OverallsAntithesis.SDK.Details.to_wire(valid)

    refute OverallsAntithesis.SDK.Details.valid?(%OverallsAntithesis.SDK.Details{retry_count: -1})
  end

  @tag obligation: "overalls_antithesis_sdk.sdk.I3"
  test "property wire preserves assertion kind and omits details on misses" do
    property = %OverallsAntithesis.SDK.Property{
      kind: :always,
      message: "m",
      module: "M",
      function: "f",
      file: "x",
      line: 1
    }

    wire =
      OverallsAntithesis.SDK.Property.wire(property, false, true, %OverallsAntithesis.SDK.Details{
        accepted_count: 1
      })

    refute Map.has_key?(wire["antithesis_assert"], "details")
    assert wire["antithesis_assert"]["assert_type"] == "always"
  end

  @tag obligation: "overalls_antithesis_sdk.sdk.I4"
  test "details reject values beyond wire bounds" do
    refute OverallsAntithesis.SDK.Details.valid?(%OverallsAntithesis.SDK.Details{elapsed_ms: -1})

    refute OverallsAntithesis.SDK.Details.valid?(%OverallsAntithesis.SDK.Details{
             accepted_count: 9_223_372_036_854_775_808
           })
  end
end
