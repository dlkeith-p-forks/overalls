defmodule Lilly.Host.ZFSIOTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.Host.ZFSIO

  property "native rate rows preserve measured zero and ignore space columns" do
    check all(
            rates <- list_of(integer(0..1_000_000), length: 4),
            allocated <- integer(0..1_000_000_000),
            free <- integer(0..1_000_000_000)
          ) do
      output = Enum.join(["tank", allocated, free | rates], "\t") <> "\n"
      assert {:ok, %{"tank" => io}} = ZFSIO.parse_rates(output, ["tank"])
      assert Map.values(io) |> Enum.sort() == Enum.sort(rates)
      assert io["read_iops"] == Enum.at(rates, 0)
      assert io["write_iops"] == Enum.at(rates, 1)
      assert io["read_bytes_per_second"] == Enum.at(rates, 2)
      assert io["write_bytes_per_second"] == Enum.at(rates, 3)
      refute Map.has_key?(io, "free_bytes")
    end
  end

  property "arbitrary utility bytes cannot crash either parser" do
    check all(output <- binary(max_length: 4096)) do
      assert match?(:error, ZFSIO.parse_rates(output, ["tank"])) or
               match?({:ok, %{}}, ZFSIO.parse_rates(output, ["tank"]))

      assert match?(:error, ZFSIO.parse_identities(output, ["tank"])) or
               match?({:ok, %{}}, ZFSIO.parse_identities(output, ["tank"]))
    end
  end

  test "rate rows require exactly the expected pools and bounded canonical fields" do
    row = "tank\t123\t456\t0\t0\t0\t0\n"
    other = String.replace(row, "tank", "archive")
    assert {:ok, %{"tank" => %{"read_iops" => 0}}} = ZFSIO.parse_rates(row, ["tank"])
    assert {:ok, rates} = ZFSIO.parse_rates(other <> row, ["tank", "archive"])
    assert map_size(rates) == 2

    for malformed <- [
          row <> row,
          row <> other,
          other,
          String.trim(row),
          row <> "\n",
          "header\n" <> row,
          String.replace(row, "123", "01"),
          String.replace(row, "123", "-1"),
          String.replace(row, "123", "1.0"),
          String.replace(row, "123", "9223372036854775808"),
          String.replace(row, "123", "+1"),
          String.replace(row, "123", "1e2"),
          String.replace(row, "123", "\t123"),
          String.duplicate("x", 65_537)
        ] do
      assert :error = ZFSIO.parse_rates(malformed, ["tank"])
    end

    assert :error = ZFSIO.parse_rates(row, ["tank", "tank"])
    assert :error = ZFSIO.parse_rates(row, ["tank", "archive"])
    names = Enum.map(1..64, &"pool#{&1}")
    rows = Enum.map_join(names, &String.replace(row, "tank", &1))
    assert {:ok, parsed} = ZFSIO.parse_rates(rows, names)
    assert map_size(parsed) == 64
    assert :error = ZFSIO.parse_rates(rows <> row, ["tank" | names])
  end

  test "both permanent and per-import GUIDs are exact unsigned strings" do
    row = "tank\tguid\t18446744073709551615\ntank\tload_guid\t123\n"

    assert {:ok, %{"tank" => %{"guid" => "18446744073709551615", "load_guid" => "123"}}} =
             ZFSIO.parse_identities(row, ["tank"])

    for malformed <- [
          row <> row,
          String.trim(row),
          String.replace(row, "load_guid", "guid"),
          String.replace(row, "load_guid", "name"),
          String.replace(row, "123", "0"),
          String.replace(row, "123", "0123"),
          String.replace(row, "123", "18446744073709551616"),
          String.replace(row, "load_guid", "load_guid\textra")
        ] do
      assert :error = ZFSIO.parse_identities(malformed, ["tank"])
    end

    assert :error = ZFSIO.parse_identities(row, ["tank", "archive"])
    assert {:ok, %{}} = ZFSIO.sample([])
  end
end
