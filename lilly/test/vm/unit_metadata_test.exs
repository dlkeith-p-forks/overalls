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

    arguments = Lilly.VM.Unit.arguments(config, pool, spec, intent, kernel)
    refute "--enable-pci" in arguments
    refute "--metadata" in arguments

    # A firmware bundle only appends the PCI transport and the MMDS metadata file
    # right after the Firecracker configuration file; everything else is identical.
    pci = Lilly.VM.Unit.arguments(config, pool, spec, intent, firmware)
    assert pci -- ["--enable-pci", "--metadata", "/metadata.json"] == arguments
    index = Enum.find_index(pci, &(&1 == "/firecracker.json"))
    assert Enum.slice(pci, index + 1, 3) == ["--enable-pci", "--metadata", "/metadata.json"]
    assert "--description=Overalls VM v1 placement=#{placement} epoch=7 generation=9" in arguments
    assert "--parent-cgroup" in arguments
    assert "lilly.slice/lilly-vm-#{placement}.service" in arguments
    assert "/tools/boot-log" in arguments
    assert "/tmp/vms/#{placement}/boot.log" in arguments
    {_systemd_options, command} = Enum.split_while(arguments, &(&1 != "--"))

    assert [
             "--",
             "/tools/boot-log",
             _,
             "/tools/unshare",
             "--fork",
             "--pid",
             "--kill-child=KILL",
             "/tools/unshare",
             "--mount-proc",
             "/tools/guard" | _
           ] = command

    refute Enum.any?(arguments, &String.starts_with?(&1, "--property=StandardOutput="))

    next =
      Lilly.VM.Unit.arguments(
        config,
        pool,
        spec,
        %{intent | execution_epoch: 8, generation: 1},
        kernel
      )

    assert "--description=Overalls VM v1 placement=#{placement} epoch=8 generation=1" in next
    refute arguments == next
  end
end
