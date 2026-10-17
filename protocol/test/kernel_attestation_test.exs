defmodule OverallsProtocol.KernelAttestationTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.KernelAttestation

  @placement "11111111-1111-4111-8111-111111111111"
  @boot "22222222-2222-4222-8222-222222222222"
  @challenge String.duplicate("a", 64)
  @digest String.duplicate("b", 64)
  @expectation %{
    placement_id: @placement,
    execution_epoch: 9,
    boot_challenge: @challenge,
    os: :freebsd,
    kernel_sha256: @digest
  }

  defp wire do
    %{
      "version" => 1,
      "state" => "attested",
      "os" => "freebsd",
      "placement_id" => @placement,
      "execution_epoch" => 9,
      "boot_challenge" => @challenge,
      "boot_id" => @boot,
      "kernel_sha256" => @digest
    }
  end

  test "closed native response verifies every boot and kernel identity" do
    assert {:ok, @boot} = KernelAttestation.verify(wire(), @expectation)

    for {field, value} <- [
          {"placement_id", @boot},
          {"execution_epoch", 10},
          {"boot_challenge", String.duplicate("c", 64)},
          {"os", "illumos"},
          {"kernel_sha256", String.duplicate("c", 64)}
        ] do
      assert {:error, :stale_attestation} =
               KernelAttestation.verify(Map.put(wire(), field, value), @expectation)
    end
  end

  test "unknown, malformed, unsupported and peer enum values refuse" do
    for value <- [
          Map.put(wire(), "extra", true),
          Map.put(wire(), "os", "freebsd-v2"),
          Map.put(wire(), "kernel_sha256", String.duplicate("A", 64)),
          Map.put(wire(), "boot_id", "not-a-uuid"),
          Map.put(wire(), "version", 2)
        ] do
      assert {:error, reason} = KernelAttestation.response(value)
      assert reason in [:invalid_message, :unsupported_version]
    end
  end
end
