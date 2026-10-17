defmodule Marshall.ComputeFixtures do
  alias Marshall.Compute.{Host, HostReports, Images, Ledger, StoragePool}

  # Small synthetic artifacts for control/receipt tests; these cannot boot a VM.
  def image_files,
    do: %{
      "kernel" => "synthetic kernel",
      "initrd" => "synthetic initrd",
      "rootfs.ext4" => "synthetic rootfs"
    }

  def image_manifest do
    artifacts =
      Map.new(image_files(), fn {name, bytes} ->
        key = if name == "rootfs.ext4", do: "rootfs", else: name

        {key,
         %{
           "bytes" => byte_size(bytes),
           "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
         }}
      end)

    Map.merge(artifacts, %{
      "version" => 4,
      "workspace_source_version" => 2,
      "architecture" => "x86_64",
      "boot_args" => "console=ttyS0",
      "minimum_memory_bytes" => 536_870_912,
      "minimum_disk_bytes" => 2_147_483_648
    })
  end

  def image_id do
    {:ok, image} = OverallsProtocol.ImageManifest.validate(image_manifest())
    image.id
  end

  # Synthetic firmware-booted (version 5) manifest with no guest agents, shaped
  # like the Windows image's manifest; nothing here boots a guest.
  def windows_image_manifest do
    %{
      "version" => 5,
      "architecture" => "x86_64",
      "boot" => %{
        "kind" => "firmware",
        "pci" => true,
        "firmware" => %{"bytes" => 4_194_304, "sha256" => String.duplicate("b", 64)}
      },
      "root" => %{
        "format" => "raw-gpt",
        "bytes" => 34_359_738_368,
        "sha256" => String.duplicate("c", 64)
      },
      "guest_agents" => "none",
      "minimum_memory_bytes" => 2_147_483_648,
      "minimum_disk_bytes" => 34_359_738_368,
      "workspace_source_version" => nil
    }
  end

  # The same firmware shape declaring the Windows agent set (readiness, trust,
  # terminal, SSH and agents; no editor, no Inception).
  def windows_v1_image_manifest do
    windows_image_manifest()
    |> Map.put("guest_agents", "windows-v1")
    |> Map.put("workspace_source_version", 2)
  end

  def windows_v1_image_fixture do
    {:ok, image} = Images.register(windows_v1_image_manifest(), "Windows Server 2025 (agents)")
    image
  end

  def windows_image_id do
    {:ok, image} = OverallsProtocol.ImageManifest.validate(windows_image_manifest())
    image.id
  end

  def windows_image_fixture do
    {:ok, image} = Images.register(windows_image_manifest(), "Windows Server 2025")
    image
  end

  def image_fixture do
    {:ok, image} = Images.register(image_manifest(), "synthetic-test-image")
    image
  end

  # Synthetic Ubuntu-shaped manifest for admission tests; native Nix checks boot
  # the actual published artifact rather than treating these bytes as a guest.
  def ubuntu_image_fixture(fixture) do
    manifest =
      Map.put(
        image_manifest(),
        "boot_args",
        "console=ttyS0 root=/dev/vda rw net.ifnames=0 ipv6.disable=1"
      )

    {:ok, image} = Images.register(manifest, "Ubuntu 26.04 LTS")

    report = %{
      fixture.report
      | sequence: fixture.report.sequence + 1,
        inventory: Map.put(fixture.report.inventory, "images", [image_id(), image.id])
    }

    {:ok, :ok} = HostReports.ingest(fixture.host.id, fixture.epoch, report)
    image
  end

  def user do
    name = Ash.UUID.generate() |> String.replace("-", "") |> binary_part(0, 20)
    Ash.Seed.seed!(Marshall.Accounts.User, %{email: "compute-#{name}@example.test"})
  end

  def request(overrides \\ %{}) do
    Map.merge(
      %{
        idempotency_key: Ash.UUID.generate(),
        architecture: :x86_64,
        image_id: image_id(),
        profile: :standard,
        vcpu: 2,
        memory_bytes: 536_870_912,
        disk_bytes: 2_147_483_648
      },
      overrides
    )
  end

  def transfer_endpoint do
    %{
      "address" => "lilly.example.test",
      "port" => 2222,
      "host_key" => "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 1::256>>)
    }
  end

  def host_fixture(overrides \\ %{}, pool_overrides \\ %{}) do
    image_fixture()

    host =
      Ledger.create!(
        Host,
        :enroll,
        Map.merge(
          %{
            name: "host-#{Ash.UUID.generate()}",
            transfer_endpoint: transfer_endpoint(),
            architecture: :x86_64,
            machine_id: "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
            overhead_cores: 1,
            overhead_memory_bytes: 1_073_741_824
          },
          overrides
        )
      )

    pool = pool_fixture(host, pool_overrides)

    host = Ledger.update!(host, :configure, %{enabled: true})
    {:ok, epoch} = HostReports.connect(host.id)
    report = report(pool)
    {:ok, :ok} = HostReports.ingest(host.id, epoch, report)
    [host] = Ledger.read!(Host, id: host.id)
    %{host: host, pool: pool, epoch: epoch, report: report}
  end

  def pool_fixture(host, overrides \\ %{}) do
    Ledger.create!(StoragePool, :enroll, pool_attributes(host.id, overrides))
  end

  def pool_attributes(host_id, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          host_id: host_id,
          name: "guests",
          backend: :zfs,
          zpool_guid: "1",
          dataset_guid: "2",
          dataset: "fixture/lilly",
          overhead_bytes: 1_073_741_824
        },
        overrides
      )

    Map.put(attrs, :filesystem_id, "zfs:#{attrs.zpool_guid}:#{attrs.dataset_guid}")
  end

  def storage_observation(pool, total, free) do
    %{
      backend: :zfs,
      zpool_guid: pool.zpool_guid,
      dataset_guid: pool.dataset_guid,
      dataset: pool.dataset,
      used_bytes: total - free,
      quota_bytes: total
    }
  end

  def capacity(cores \\ 5, memory \\ 4_294_967_296) do
    %{
      "version" => 1,
      "cpu_headroom_millicores" => cores * 1000,
      "memory_headroom_bytes" => memory,
      "interval_us" => 1_000_000,
      "covered" => %{}
    }
  end

  def report(pool) do
    %{
      sequence: 1,
      sampled_at: Ledger.now(),
      effective_cores: 5,
      effective_memory_bytes: 4_294_967_296,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [image_id()],
        "execution_ready" => true,
        "terminal_protocol" => 2,
        "inception_image_id" => nil
      },
      capacity: %{
        "version" => 1,
        "cpu_headroom_millicores" => 5000,
        "memory_headroom_bytes" => 4_294_967_296,
        "interval_us" => 1_000_000,
        "covered" => %{}
      },
      pools: [
        %{
          id: pool.id,
          total_bytes: 10_737_418_240,
          free_bytes: 10_737_418_240,
          allocations: %{},
          storage: storage_observation(pool, 10_737_418_240, 10_737_418_240)
        }
      ]
    }
  end
end
