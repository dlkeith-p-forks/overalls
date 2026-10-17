defmodule OverallsAntithesis.Lilly.IntegratedOwnershipTest do
  use ExUnit.Case, async: true

  alias OverallsAntithesis.Lilly.IntegratedOwnership

  @placement "33333333-3333-4333-8333-333333333333"

  test "fixed harness units are allowed with no tracked guests" do
    assert IntegratedOwnership.fixed_native_inventory?(
             ["lilly.service"],
             ["lilly.service", "lilly-guest-emulator.service"],
             MapSet.new()
           )
  end

  test "unknown fixed-slice service is rejected" do
    refute IntegratedOwnership.fixed_native_inventory?(
             [],
             ["lilly.service", "unknown.service"],
             MapSet.new()
           )
  end

  test "an expected VM may be owned by the shared emulator service" do
    expected = MapSet.new(["lilly-vm-#{@placement}.service"])

    assert IntegratedOwnership.fixed_native_inventory?(
             [],
             ["lilly.service", "lilly-guest-emulator.service"],
             expected
           )
  end

  test "an expected VM is accepted only when observed alongside fixed units" do
    expected = MapSet.new(["lilly-vm-#{@placement}.service"])

    assert IntegratedOwnership.fixed_native_inventory?(
             ["lilly-vm-#{@placement}.service"],
             ["lilly.service", "lilly-guest-emulator.service"],
             expected
           )
  end

  test "unknown VM units remain rejected" do
    refute IntegratedOwnership.fixed_native_inventory?(
             ["lilly-vm-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.service"],
             ["lilly.service", "lilly-guest-emulator.service"],
             MapSet.new()
           )
  end

  test "oversized or malformed unit output fails closed" do
    assert :error = IntegratedOwnership.parse_units(String.duplicate("x", 65_537))
    assert :error = IntegratedOwnership.parse_units(<<0>>)
    assert {:ok, ["lilly.service"]} = IntegratedOwnership.parse_units("lilly.service\n")
  end
end
