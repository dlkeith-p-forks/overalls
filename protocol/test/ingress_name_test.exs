defmodule OverallsProtocol.IngressNameTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.IngressName

  property "full immutable IDs survive name truncation within DNS label limits" do
    check all(bytes <- binary(length: 16), suffix <- string(:alphanumeric, max_length: 50)) do
      hex = Base.encode16(bytes, case: :lower)

      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex

      id = Enum.join([a, b, c, d, e], "-")
      name = "vm" <> String.downcase(suffix)
      result = IngressName.label(name, id)
      assert IngressName.valid_label?(result)
      assert byte_size(result) <= 63
      assert String.ends_with?(result, hex)
    end
  end

  property "alternate ports remain single labels and preserve the full VM identity" do
    label =
      IngressName.label(
        "a-very-long-application-machine-name",
        "11111111-1111-4111-8111-111111111111"
      )

    check all(port <- integer(3000..9999)) do
      alternate = IngressName.alternate_label(label, port)
      assert byte_size(alternate) <= 63
      assert String.ends_with?(alternate, "11111111111141118111111111111111")
      assert {:ok, ^port} = IngressName.alternate_port(alternate, label)
    end
  end

  test "alternate labels reject ambiguous and out-of-range spellings" do
    for value <- ["p22", "p2999", "p10000", "p03000", "p3000.evil", "P3000", nil] do
      assert :error = IngressName.alternate_port(value)
    end
  end

  test "alternate names cannot exceed one DNS label" do
    long = "v-" <> String.duplicate("a", 27) <> "-" <> String.duplicate("1", 32)
    assert byte_size(long) == 62
    assert IngressName.valid_label?(long)
    assert_raise ArgumentError, fn -> IngressName.alternate_label(long, 3000) end
    assert :error = IngressName.alternate_port("p3000-" <> long, long)
    assert :error = IngressName.application_label("p3000-" <> long)
  end
end
