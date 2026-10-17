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
end
