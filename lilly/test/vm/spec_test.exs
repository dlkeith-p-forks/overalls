defmodule Lilly.VM.SpecTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.VM.Spec

  defp valid do
    %{
      id: "9af58c48-2846-4c31-985a-a1d7efedb71a",
      image_id: "sha256:" <> String.duplicate("a", 64),
      pool_id: "404a94b4-f63a-4e67-9f37-a53b1ef11393",
      profile: :customer,
      slot: 2,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }
  end

  property "execution preserves exact aligned guest sizes and reserves VMM memory separately" do
    check all(
            cpu <- integer(1..32),
            memory_mib <- integer(512..262_144),
            disk_blocks <- integer(524_288..131_072_000)
          ) do
      input = %{
        valid()
        | vcpu: cpu,
          memory_bytes: memory_mib * 1_048_576,
          disk_bytes: disk_blocks * 4096
      }

      assert {:ok, spec} = Spec.new(input)
      assert spec.memory_bytes == input.memory_bytes
      assert spec.disk_bytes == input.disk_bytes
      assert Spec.host_memory(spec) == input.memory_bytes + 67_108_864
      assert Spec.encode(spec)["vcpu"] == cpu
    end
  end

  test "rejects imprecise sizes, extra fields and invalid identities before host effects" do
    for {key, value} <- [
          vcpu: 0,
          vcpu: 33,
          memory_bytes: 536_870_913,
          disk_bytes: 2_147_483_649,
          disk_bytes: 536_870_916_096,
          slot: 1,
          slot: 65535,
          profile: :unknown,
          image_id: "latest",
          id: "../escape"
        ] do
      assert {:error, :invalid_vm_specification} = Spec.new(Map.put(valid(), key, value))
    end

    assert {:error, :invalid_vm_specification} = Spec.new(Map.put(valid(), :command, "shell"))
  end

  test "an optional workspace source is carried but never enters persisted encodings" do
    source = %{
      provider: :github,
      namespace: ["octo"],
      repository: "demo",
      revision: %{kind: :ref, value: "feature/x"}
    }

    assert {:ok, plain} = Spec.new(valid())
    assert {:ok, spec} = Spec.new(Map.put(valid(), :workspace_source, source))
    assert spec.workspace_source == source
    assert plain.workspace_source == nil
    assert Spec.encode(spec) == Spec.encode(plain)
    # Claim, snapshot and adoption checks compare the storage shape, so a start
    # command carrying a source still matches what a stopped command journaled.
    assert Spec.storage(spec) == plain
    assert Spec.storage(plain) == plain
    refute spec == plain

    for invalid <- [
          nil,
          %{source | namespace: ["-octo"]},
          %{source | revision: %{kind: :unknown}},
          %{owner: "octo", repo: "demo", ref_kind: :branch, ref: "feature/x"},
          Map.put(source, :url, "https://github.com/octo/demo")
        ] do
      assert {:error, :invalid_vm_specification} =
               Spec.new(Map.put(valid(), :workspace_source, invalid))
    end

    assert {:error, :invalid_vm_specification} =
             Spec.new(valid() |> Map.put(:workspace_source, source) |> Map.delete(:slot))
  end
end
