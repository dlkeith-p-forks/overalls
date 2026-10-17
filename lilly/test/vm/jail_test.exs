defmodule Lilly.VM.JailTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Pool
  alias Lilly.VM.Jail

  property "accepted pool paths leave room for a full VM socket address, measured in bytes" do
    check all(
            name <- string(:alphanumeric, min_length: 1, max_length: 80),
            unicode <- integer(0..20)
          ) do
      path = "/" <> name <> String.duplicate("é", unicode)
      pool = struct(Pool, path: path)

      actual =
        Path.join([
          path,
          ".lilly-jails",
          "firecracker",
          Lilly.UUID.generate(),
          "root",
          "api.sock"
        ])

      assert Jail.supports_pool?(pool) == byte_size(actual) < 108
    end
  end

  test "the maximum accepted path can bind a real Unix socket" do
    directory = "/tmp/kj-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    pool = struct(Pool, path: String.pad_trailing(directory, 31, "x"))

    socket =
      Path.join([
        pool.path,
        ".lilly-jails",
        "firecracker",
        Lilly.UUID.generate(),
        "root",
        "api.sock"
      ])

    on_exit(fn -> File.rm_rf!(pool.path) end)
    File.mkdir_p!(Path.dirname(socket))
    assert Jail.supports_pool?(pool)
    assert {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, socket}])
    :gen_tcp.close(listener)
    refute Jail.supports_pool?(%{pool | path: pool.path <> "x"})

    refute Jail.supports_pool?(
             struct(Pool, path: "/tmp/lilly-deployment-" <> Lilly.UUID.generate())
           )
  end

  test "Firecracker readiness configuration uses the persisted placement boot identity" do
    placement = "11111111-1111-4111-8111-111111111111"

    {:ok, spec} =
      Lilly.VM.Spec.new(%{
        id: placement,
        image_id: "sha256:" <> String.duplicate("a", 64),
        pool_id: "22222222-2222-4222-8222-222222222222",
        profile: :customer,
        slot: 2,
        vcpu: 1,
        memory_bytes: 536_870_912,
        disk_bytes: 2_147_483_648
      })

    bundle = %{
      image_id: spec.image_id,
      architecture: :x86_64,
      boot_kind: :kernel,
      guest_agents: :linux,
      boot_args: "console=ttyS0 root=/dev/vda rw",
      kernel_bytes: 1,
      initrd_bytes: 1
    }

    boot = %{
      placement_id: placement,
      execution_epoch: 7,
      generation: 3,
      boot_challenge: String.duplicate("b", 64)
    }

    config = Jail.configuration(bundle, spec, boot)
    assert config["vsock"] == %{"guest_cid" => 3, "uds_path" => "/v.sock"}
    refute Map.has_key?(config, "cpu-config")
    refute Map.has_key?(config, "mmds-config")
    assert config["boot-source"]["initrd_path"] == "/initrd"
    parameters = String.split(config["boot-source"]["boot_args"])
    assert ("lilly.placement=" <> placement) in parameters
    assert "lilly.execution_epoch=7" in parameters
    assert ("lilly.boot_challenge=" <> boot.boot_challenge) in parameters
    assert "lilly.ipv4=10.10.0.2" in parameters
    assert config["network-interfaces"] |> hd() |> Map.fetch!("guest_mac") == spec.network.mac

    {:ok, network} = Lilly.Network.Guest.new(placement, :inception, 2)
    inception = %{spec | network: network, disk_bytes: 64 * 1024 ** 3}
    nested_config = Jail.configuration(bundle, inception, boot)
    assert [root, data] = nested_config["drives"]
    assert root["is_root_device"]
    assert root["path_on_host"] == "/rootfs.ext4"
    refute data["is_root_device"]
    assert data["path_on_host"] == "/data.raw"

    for drive <- [root, data] do
      assert drive["cache_type"] == "Writeback"
      assert drive["io_engine"] == "Sync"
      refute drive["is_read_only"]
    end

    assert Lilly.VM.Spec.storage_bytes(inception) == 321 * 1024 ** 3
  end

  test "firmware bundles boot the firmware over virtio-pci with MMDS identity and no vsock" do
    placement = "11111111-1111-4111-8111-111111111111"

    {:ok, spec} =
      Lilly.VM.Spec.new(%{
        id: placement,
        image_id: "sha256:" <> String.duplicate("a", 64),
        pool_id: "22222222-2222-4222-8222-222222222222",
        profile: :customer,
        slot: 2,
        vcpu: 2,
        memory_bytes: 2_147_483_648,
        disk_bytes: 34_359_738_368
      })

    bundle = %{
      image_id: spec.image_id,
      architecture: :x86_64,
      boot_kind: :firmware,
      guest_agents: :none,
      pci: true,
      firmware_bytes: 4_194_304
    }

    boot = %{
      placement_id: placement,
      execution_epoch: 7,
      generation: 3,
      boot_challenge: String.duplicate("b", 64)
    }

    config = Jail.configuration(bundle, spec, boot)
    assert config["boot-source"] == %{"kernel_image_path" => "/firmware"}
    refute Map.has_key?(config, "vsock")
    assert config["cpu-config"] == %{"hyperv" => true}
    assert config["mmds-config"] == %{"version" => "V2", "network_interfaces" => ["eth0"]}

    assert config["machine-config"] == %{
             "vcpu_count" => 2,
             "mem_size_mib" => 2048,
             "smt" => false
           }

    assert [root] = config["drives"]
    assert root["path_on_host"] == "/rootfs.ext4" and root["is_root_device"]
    assert root["cache_type"] == "Writeback" and root["io_engine"] == "Sync"
    assert config["network-interfaces"] |> hd() |> Map.fetch!("guest_mac") == spec.network.mac
    refute JSON.encode!(config) =~ "lilly."

    metadata = Jail.metadata(bundle, spec, boot)

    assert metadata == %{
             "lilly" => %{
               "version" => 1,
               "placement" => placement,
               "execution_epoch" => 7,
               "boot_challenge" => boot.boot_challenge,
               "ipv4" => "10.10.0.2",
               "prefix_length" => 32,
               "gateway" => "10.10.0.1",
               "mac" => spec.network.mac
             }
           }

    # The Windows agent set speaks the Linux vsock protocols, so its firmware
    # jail gets the same jail-local vsock endpoint and nothing else changes.
    with_agents = Jail.configuration(%{bundle | guest_agents: :windows_v1}, spec, boot)
    assert with_agents["vsock"] == %{"guest_cid" => 3, "uds_path" => "/v.sock"}
    assert Map.delete(with_agents, "vsock") == config
    assert Jail.metadata(%{bundle | guest_agents: :windows_v1}, spec, boot) == metadata

    refute JSON.encode!(metadata) =~ "generation"
    refute JSON.encode!(metadata) =~ "/"

    # Native FreeBSD images use the same PVH firmware transport and the shared
    # guest protocol over vsock; they must also not receive the Windows-only
    # Hyper-V CPU template.
    freebsd = Map.merge(bundle, %{guest_agents: :freebsd_v1, os: :freebsd})
    freebsd_config = Jail.configuration(freebsd, spec, boot)
    assert freebsd_config["vsock"] == %{"guest_cid" => 3, "uds_path" => "/v.sock"}
    refute Map.has_key?(freebsd_config, "cpu-config")
  end

  test "native FreeBSD firmware bundles use PVH firmware with the shared agent transport" do
    placement = "11111111-1111-4111-8111-111111111111"

    {:ok, spec} =
      Lilly.VM.Spec.new(%{
        id: placement,
        image_id: "sha256:" <> String.duplicate("a", 64),
        pool_id: "22222222-2222-4222-8222-222222222222",
        profile: :customer,
        slot: 2,
        vcpu: 1,
        memory_bytes: 536_870_912,
        disk_bytes: 2_147_483_648
      })

    bundle = %{
      image_id: spec.image_id,
      architecture: :x86_64,
      boot_kind: :firmware,
      guest_agents: :freebsd_v1,
      os: :freebsd,
      pci: true,
      firmware_bytes: 4_194_304
    }

    boot = %{
      placement_id: placement,
      execution_epoch: 7,
      generation: 3,
      boot_challenge: String.duplicate("b", 64)
    }

    config = Jail.configuration(bundle, spec, boot)
    assert config["boot-source"] == %{"kernel_image_path" => "/firmware"}
    assert config["vsock"] == %{"guest_cid" => 3, "uds_path" => "/v.sock"}
    refute Map.has_key?(config, "cpu-config")
    assert config["mmds-config"] == %{"version" => "V2", "network_interfaces" => ["eth0"]}
  end

  test "native illumos firmware bundles use PVH firmware with the shared agent transport" do
    placement = "11111111-1111-4111-8111-111111111111"

    {:ok, spec} =
      Lilly.VM.Spec.new(%{
        id: placement,
        image_id: "sha256:" <> String.duplicate("a", 64),
        pool_id: "22222222-2222-4222-8222-222222222222",
        profile: :customer,
        slot: 2,
        vcpu: 1,
        memory_bytes: 536_870_912,
        disk_bytes: 2_147_483_648
      })

    bundle = %{
      image_id: spec.image_id,
      architecture: :x86_64,
      boot_kind: :firmware,
      guest_agents: :illumos_v1,
      os: :illumos,
      pci: true,
      firmware_bytes: 4_194_304
    }

    boot = %{
      placement_id: placement,
      execution_epoch: 7,
      generation: 3,
      boot_challenge: String.duplicate("b", 64)
    }

    config = Jail.configuration(bundle, spec, boot)
    assert config["boot-source"] == %{"kernel_image_path" => "/firmware"}
    assert config["vsock"] == %{"guest_cid" => 3, "uds_path" => "/v.sock"}
    refute Map.has_key?(config, "cpu-config")
  end

  test "guest boot configuration contains no SSH key" do
    placement = "11111111-1111-4111-8111-111111111111"

    {:ok, spec} =
      Lilly.VM.Spec.new(%{
        id: placement,
        image_id: "sha256:" <> String.duplicate("a", 64),
        pool_id: "22222222-2222-4222-8222-222222222222",
        profile: :customer,
        slot: 2,
        vcpu: 1,
        memory_bytes: 536_870_912,
        disk_bytes: 2_147_483_648
      })

    bundle = %{
      image_id: spec.image_id,
      architecture: :x86_64,
      boot_kind: :kernel,
      guest_agents: :linux,
      boot_args: "console=ttyS0 root=/dev/vda rw",
      kernel_bytes: 1,
      initrd_bytes: 1
    }

    boot = %{
      placement_id: placement,
      execution_epoch: 1,
      generation: 1,
      boot_challenge: String.duplicate("b", 64)
    }

    ordinary = Jail.configuration(bundle, spec, boot)["boot-source"]["boot_args"]
    refute String.contains?(ordinary, "lilly.ssh_key=")
  end
end
