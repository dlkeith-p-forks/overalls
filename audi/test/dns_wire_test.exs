defmodule Audi.DNS.WireTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.DNS.Wire

  property "arbitrary packets always produce a bounded result" do
    check all(packet <- binary(max_length: 2048)) do
      assert match?({:error, _}, Wire.decode(packet)) or match?({:ok, _}, Wire.decode(packet))
    end
  end

  property "valid questions preserve identity and normalize only ASCII case" do
    check all(
            id <- integer(0..65_535),
            type <- integer(0..65_535),
            label <- string(:alphanumeric, min_length: 1, max_length: 63)
          ) do
      packet =
        <<id::16, 0x0100::16, 1::16, 0::16, 0::16, 0::16, byte_size(label), label::binary, 0,
          type::16, 1::16>>

      assert {:ok, question} = Wire.decode(packet)
      assert question.id == id
      assert question.type == type
      assert question.labels == [String.downcase(label)]
      assert question.udp_size == 512
    end
  end

  test "rejects cyclic pointers, oversized labels, trailing bytes and truncated records" do
    header = <<1::16, 0::16, 1::16, 0::16, 0::16, 0::16>>

    for name <- [<<0xC0, 12>>, <<64, 0>>, <<3, "ab">>, <<0, 1::16, 1::16, 0>>] do
      assert {:error, :malformed} = Wire.decode(header <> name)
    end
  end

  test "EDNS advertises a bounded UDP size and validates option framing" do
    question = <<1::16, 0::16, 1::16, 0::16, 0::16, 1::16, 0, 1::16, 1::16>>
    opt = <<0, 41::16, 65_535::16, 0::32, 0::16>>
    assert {:ok, %{udp_size: 1232, edns: true}} = Wire.decode(question <> opt)
    assert {:error, :malformed} = Wire.decode(question <> opt <> <<0>>)
  end

  test "the 255-octet name limit includes label prefixes and root" do
    header = <<1::16, 0::16, 1::16, 0::16, 0::16, 0::16>>
    prefix = :binary.copy(<<63>> <> :binary.copy("a", 63), 3)
    suffix = <<0, 1::16, 1::16>>
    valid = header <> prefix <> <<61>> <> :binary.copy("b", 61) <> suffix
    oversized = header <> prefix <> <<62>> <> :binary.copy("b", 62) <> suffix
    assert {:ok, _} = Wire.decode(valid)
    assert {:error, :malformed} = Wire.decode(oversized)
  end

  test "non-ASCII label octets do not enter Unicode parsing" do
    packet = <<1::16, 0::16, 1::16, 0::16, 0::16, 0::16, 2, 255, ?A, 0, 1::16, 1::16>>
    assert {:ok, %{labels: [<<255, ?a>>]}} = Wire.decode(packet)
  end

  test "unknown EDNS versions remain available for BADVERS responses" do
    packet =
      <<1::16, 0::16, 1::16, 0::16, 0::16, 1::16, 0, 1::16, 1::16, 0, 41::16, 512::16, 0, 9,
        0::16, 0::16>>

    assert {:ok, %{edns_version: 9}} = Wire.decode(packet)
  end
end
