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
    cpu = draw("cpu", integer(1..32))
    memory_mib = draw("memory_mib", integer(512..262_144))
    disk_blocks = draw("disk_blocks", integer(524_288..131_072_000))

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

  property "boot attribution never changes storage identity and both transports agree" do
    name = draw("author name", string(:alphanumeric, min_length: 1, max_length: 128))
    mailbox = draw("author mailbox", string(:alphanumeric, min_length: 1, max_length: 40))
    with_source = draw("with workspace source", boolean())
    identity = %{name: name, email: mailbox <> "@example.test"}

    source = %{
      provider: :github,
      namespace: ["example"],
      repository: "demo",
      revision: %{kind: :default}
    }

    input = Map.put(valid(), :git_identity, identity)
    input = if with_source, do: Map.put(input, :workspace_source, source), else: input
    assert {:ok, spec} = Spec.new(input)
    assert {:ok, plain} = Spec.new(valid())
    assert spec.git_identity == identity
    assert Spec.storage(spec) == plain
    assert Spec.encode(spec) == Spec.encode(plain)

    boot = %{
      placement_id: spec.id,
      execution_epoch: 7,
      boot_challenge: String.duplicate("b", 64)
    }

    kernel = %{boot_kind: :kernel, guest_agents: :linux, boot_args: "quiet"}
    config = Lilly.VM.Jail.configuration(kernel, spec, boot)

    encoded =
      config["boot-source"]["boot_args"]
      |> String.split()
      |> Enum.find(&String.starts_with?(&1, "lilly.git_identity="))
      |> String.replace_prefix("lilly.git_identity=", "")

    assert {:ok, bytes} = Base.url_decode64(encoded, padding: false)
    assert {:ok, wire} = JSON.decode(bytes)
    assert wire == OverallsProtocol.GitIdentity.encode(identity)

    assert Lilly.VM.Jail.metadata(%{boot_kind: :firmware}, spec, boot)["lilly"]["git_identity"] ==
             wire

    refute Map.has_key?(
             Lilly.VM.Jail.metadata(%{boot_kind: :firmware}, plain, boot)["lilly"],
             "git_identity"
           )
  end

  test "malformed attribution refuses before privileged effects" do
    for identity <- [
          nil,
          %{name: "bad\nname", email: "a@example.test"},
          %{name: "valid", email: "missing-at"},
          %{name: "valid", email: "a@example.test", extra: true}
        ] do
      assert {:error, :invalid_vm_specification} =
               Spec.new(Map.put(valid(), :git_identity, identity))
    end
  end
end
