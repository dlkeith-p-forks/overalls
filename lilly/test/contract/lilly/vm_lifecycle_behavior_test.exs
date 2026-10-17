defmodule LillyVmLifecycleBehaviorContractTest do
  use Covenant.Case, component: "lilly.vm_lifecycle"

  @tag obligation: "lilly.vm_lifecycle.I2"
  test "VM specs validate identities and resource shape before execution" do
    valid = %{
      id: Lilly.UUID.generate(),
      image_id: "sha256:" <> String.duplicate("a", 64),
      pool_id: Lilly.UUID.generate(),
      profile: :customer,
      slot: 1,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }

    assert {:error, :invalid_vm_specification} = Lilly.VM.Spec.new(valid)
  end

  @tag obligation: "lilly.vm_lifecycle.I3"
  test "storage identity clears delivery-only workspace source" do
    id = Lilly.UUID.generate()
    pool_id = Lilly.UUID.generate()
    assert {:ok, network} = Lilly.Network.Guest.new(id, :customer, 2)

    spec = %Lilly.VM.Spec{
      id: id,
      image_id: "sha256:" <> String.duplicate("a", 64),
      pool_id: pool_id,
      network: network,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648,
      workspace_source: %{
        provider: :github,
        namespace: ["acme"],
        repository: "demo",
        revision: %{kind: :default}
      }
    }

    persisted = Lilly.VM.Spec.storage(spec)
    assert persisted.workspace_source == nil
    assert persisted.id == spec.id
    assert persisted.disk_bytes == spec.disk_bytes
  end
end
