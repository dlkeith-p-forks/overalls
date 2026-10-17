defmodule Lilly.VM.UnitMetadataTest do
  use ExUnit.Case, async: true

  test "unit metadata binds the launched revision independently of later intent" do
    placement = Lilly.UUID.generate()
    {:ok, network} = Lilly.Network.Config.new(Lilly.UUID.generate(), "eth0", [], "/tmp/net")
    {:ok, guest} = Lilly.Network.Guest.new(placement, :customer, 2)

    config = %Lilly.VM.Config{
      state_dir: "/tmp/vms",
      network: network,
      firecracker: "/tools/firecracker",
      jailer: "/tools/jailer",
      unshare: "/tools/unshare",
      launch_guard: "/tools/guard",
      boot_log_writer: "/tools/boot-log"
    }

    spec = %Lilly.VM.Spec{
      id: placement,
      image_id: "fixture",
      pool_id: Lilly.UUID.generate(),
      network: guest,
      vcpu: 2,
      memory_bytes: 1_073_741_824,
      disk_bytes: 4_294_967_296
    }

    pool = %Lilly.Host.Pool{id: spec.pool_id, path: "/tmp/pool", filesystem_id: "fixture"}
    intent = %{placement_id: placement, execution_epoch: 7, generation: 9, state: :running}

    kernel = %{
      image_id: spec.image_id,
      architecture: :x86_64,
      boot_kind: :kernel,
      guest_agents: :linux,
      boot_args: "console=ttyS0",
      kernel_bytes: 1,
      initrd_bytes: 1
    }

    firmware = %{
      image_id: spec.image_id,
      architecture: :x86_64,
      boot_kind: :firmware,
      guest_agents: :none,
      pci: true,
      firmware_bytes: 4_194_304
    }

    # The command line is built by lilly-hostd (vm_launch.rs, whose tests
    # carry the argument guarantees); Lilly sends only typed fields.
    launch = Lilly.VM.Unit.launch(config, pool, spec, intent, kernel)

    assert launch == %{
             placement: placement,
             epoch: 7,
             generation: 9,
             uid: spec.network.uid,
             memory_bytes: Lilly.VM.Spec.host_memory(spec),
             vcpus: 2,
             firmware: false,
             logging: false,
             state_dir: "/tmp/vms",
             namespace: network.namespace,
             pool: "/tmp/pool"
           }

    assert %{firmware: true} = Lilly.VM.Unit.launch(config, pool, spec, intent, firmware)

    assert %{epoch: 8, generation: 1} =
             Lilly.VM.Unit.launch(
               config,
               pool,
               spec,
               %{intent | execution_epoch: 8, generation: 1},
               kernel
             )
  end
end
