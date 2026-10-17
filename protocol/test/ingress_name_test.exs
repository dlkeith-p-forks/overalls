defmodule OverallsProtocol.IngressNameTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.IngressName

  property "full immutable IDs survive name truncation within DNS label limits",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 249_191_510 do
    bytes = draw("bytes", binary(length: 16))
    suffix = draw("suffix", OverallsProtocol.TestGenerators.string(:alphanumeric, max_length: 50))
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

  property "alternate ports remain single labels and preserve the full VM identity",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 724_588_495 do
    label =
      IngressName.label(
        "a-very-long-application-machine-name",
        "11111111-1111-4111-8111-111111111111"
      )

    (
      port = draw("port", integer(3000..9999))
      alternate = IngressName.alternate_label(label, port)
      assert byte_size(alternate) <= 63
      assert String.ends_with?(alternate, "11111111111141118111111111111111")
      assert {:ok, ^port} = IngressName.alternate_port(alternate, label)
    )
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
