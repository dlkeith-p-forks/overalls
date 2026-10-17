defmodule Lilly.Network.FlowLookupTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.Network.FlowLookup

  property "kernel endpoints retain every tuple component in fixed argv" do
    check all(a <- integer(0..255), b <- integer(0..255), port <- integer(1..65_535)) do
      assert {:ok, ["10.10.#{a}.#{b}", "#{port}", "8.8.8.8", "443"]} ==
               FlowLookup.arguments(%{
                 source: {{10, 10, a, b}, port},
                 destination: {{8, 8, 8, 8}, 443}
               })
    end
  end

  test "missing ports, malformed endpoints and ambiguous helper output are unresolved" do
    for flow <- [
          %{source: {10, 10, 0, 2}},
          %{source: {{10, 10, 0, 2}, 0}, destination: {{8, 8, 8, 8}, 443}},
          %{source: {{10, 10, 0, 256}, 12}, destination: {{8, 8, 8, 8}, 443}},
          %{source: {"10.10.0.2", 12}, destination: {{8, 8, 8, 8}, 443}}
        ] do
      assert {:error, :unresolved} = FlowLookup.arguments(flow)
    end

    label = "8" <> String.duplicate("a", 31)
    assert FlowLookup.decode(label <> "\n") == {:ok, label}

    for output <- [
          label,
          label <> "\n\n",
          String.upcase(label) <> "\n",
          String.duplicate("0", 32) <> "\n",
          label <> "\nsecret",
          nil
        ] do
      assert {:error, :unresolved} = FlowLookup.decode(output)
    end
  end
end
