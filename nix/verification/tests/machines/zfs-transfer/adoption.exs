# @cc [owner:ghuntley,label:verification] adoption-fixture-is-storage-not-guest-acceptance
# This fixture MUST use real ZFS and the production disk adoption entry point.
# Its content-verified synthetic boot artifacts MUST NOT establish guest boot,
# image compatibility or end-to-end relocation acceptance.
alias Lilly.Host.{Command, Image, Pool, ZFS, ZFSDataset}
alias Lilly.Transfer.ReceivedDataset
alias Lilly.VM.{Disk, Spec}
alias OverallsProtocol.{ImageManifest, Relocation, Storage}

action = System.fetch_env!("RECEIVED_ACTION")

artifact = %{
  "bytes" => 7,
  "sha256" => Base.encode16(:crypto.hash(:sha256, "fixture"), case: :lower)
}

manifest = %{
  "version" => 4,
  "workspace_source_version" => nil,
  "architecture" => "x86_64",
  "boot_args" => "console=ttyS0",
  "minimum_memory_bytes" => 536_870_912,
  "minimum_disk_bytes" => 2_147_483_648,
  "kernel" => artifact,
  "initrd" => artifact,
  "rootfs" => artifact
}

{:ok, manifest_info} = ImageManifest.validate(manifest)

# The driver writes each source boot bundle before the destination pool
# exists, so it asks for the image id the manifest above derives.
if action == "image-id" do
  File.write!("/run/adoption-image-id", manifest_info.id)
  System.halt(0)
end
inception? = System.fetch_env!("RECEIVED_MODE") == "adoption-inception"

suffix =
  case System.fetch_env!("RECEIVED_MODE") do
    "adoption-cancel" -> "000000000009"
    "adoption-inception" -> "000000000010"
    _ -> "000000000004"
  end

placement = "dddddddd-dddd-4ddd-8ddd-" <> suffix
host = "aaaaaaaa-aaaa-4aaa-8aaa-000000000002"
pool_id = "bbbbbbbb-bbbb-4bbb-8bbb-000000000004"
image_path = "/run/adoption-image-" <> suffix
descriptor_path = "/run/adoption-descriptor-" <> suffix <> ".json"
source = cond do
  inception? -> "source/adoption-inception"
  true -> "source/adoption"
end
{:ok, identity} = ZFS.inspect_path("/adoption-pool")

{:ok, pool} =
  Pool.new(pool_id, identity.path, identity.filesystem_id,
    host_id: host,
    storage: Storage.encode(identity.storage)
  )

if action == "prepare" do
  File.mkdir!(image_path)

  for name <- ["kernel", "initrd", "rootfs.ext4"] do
    path = Path.join(image_path, name)
    File.write!(path, "fixture")
    File.chmod!(path, 0o444)
  end

  File.write!(Path.join(image_path, "manifest.json"), JSON.encode!(manifest))
  File.chmod!(Path.join(image_path, "manifest.json"), 0o444)
  {:ok, source_guid} = Command.run(:zfs_get, ["-Hp", "-o", "value", "guid", source])

  {:ok, target_guid} =
    Command.run(:zfs_get, [
      "-Hp",
      "-o",
      "value",
      "guid",
      source <> "@lilly-b"
    ])

  {:ok, descriptor} =
    Relocation.descriptor(%{
      "version" => 3,
      "relocation_id" => "ffffffff-ffff-4fff-8fff-" <> suffix,
      "vm_id" => "eeeeeeee-eeee-4eee-8eee-" <> suffix,
      "source_epoch" => 1,
      "destination_epoch" => 2,
      "source" => %{
        "placement_id" => "dddddddd-dddd-4ddd-8ddd-000000000001",
        "host_id" => "aaaaaaaa-aaaa-4aaa-8aaa-000000000001",
        "pool_id" => "bbbbbbbb-bbbb-4bbb-8bbb-000000000001"
      },
      "destination" => %{"placement_id" => placement, "host_id" => host, "pool_id" => pool_id},
      "workload" => %{
        "image_id" => manifest_info.id,
        "architecture" => "x86_64",
        "profile" => if(inception?, do: "inception", else: "customer"),
        "slot" => if(inception?, do: 7, else: 2),
        "vcpu" => 1,
        "memory_bytes" => 536_870_912,
        "disk_bytes" => 2_147_483_648
      },
      "stream" => %{
        "source_dataset_guid" => String.trim(source_guid),
        "to_guid" => String.trim(target_guid)
      }
    })

  {:ok, _} = Lilly.Host.Storage.locked(pool, fn -> ReceivedDataset.prepare(pool, descriptor) end)
  File.write!(descriptor_path, JSON.encode!(Relocation.encode_descriptor(descriptor)))
else
  {:ok, descriptor} = File.read!(descriptor_path) |> JSON.decode!() |> Relocation.descriptor()

  load_image = fn ->
    {:ok, image} = Image.load(image_path)
    image
  end

  {:ok, spec} =
    descriptor.workload
    |> Map.drop([:architecture])
    |> Map.merge(%{id: placement, pool_id: pool.id})
    |> Spec.new()

  execution_config = fn ->
    tools = System.fetch_env!("ADOPTION_RELEASE_METADATA") |> File.read!() |> JSON.decode!()
    {:ok, network} = Lilly.Network.Config.new(host, "eth1", [], "/var/lib/import-network")
    :ok = Lilly.Network.setup(network)

    {:ok, execution} =
      Lilly.VM.Config.new(%{
        state_dir: "/var/lib/import-vms",
        network: network,
        firecracker: tools["firecracker"],
        jailer: tools["jailer"],
        unshare: tools["unshare"]
      })

    execution
  end

  case action do
    "cleanup" ->
      if System.fetch_env!("RECEIVED_MODE") == "adoption-cancel" do
        image = load_image.()
        execution = execution_config.()

        config = %{
          execution: execution,
          transfer_state_dir: "/var/lib/import-keys",
          client: %{host_id: host},
          pools: [pool]
        }

        {:ok, %{placement_id: ^placement}} =
          Lilly.Transfer.DestinationCleanup.execute(
            config,
            Relocation.encode_intent(Map.delete(descriptor, :stream)),
            System.system_time(:second) + 180
          )

        {:ok, %{state: :deleted, execution_epoch: 2, generation: 1}} =
          Lilly.VM.Intent.read(Path.join(execution.state_dir, placement))

        {:error, _} =
          Lilly.VM.Driver.start(execution, pool, image, spec, execution_epoch: 3, generation: 99)
      else
        :ok = Disk.discard_import(pool, descriptor)
      end

      {:ok, %{"phase" => "retired"}} =
        Lilly.Transfer.ImportJournal.read(
          ReceivedDataset.directory(pool, placement),
          descriptor,
          pool.storage
        )

      %{allocations: allocations} = Pool.report(pool)
      false = Map.has_key?(allocations, placement)

    "verify" ->
      {:ok, _} =
        Lilly.Host.Storage.locked(pool, fn -> ReceivedDataset.verify(pool, descriptor) end)

    action when action in ["adopt", "reject-import-authority"] ->
      execution = execution_config.()
      root = "/var/lib/import-keys"
      :ok = Lilly.Host.PrivateFiles.directory(root)
      {:ok, public} = Lilly.Transfer.Key.ensure(root, host, descriptor.relocation_id, placement)

      {:ok, journal} =
        Lilly.Transfer.ImportJournal.read(
          ReceivedDataset.directory(pool, placement),
          descriptor,
          pool.storage
        )

      command = %{
        id: descriptor.relocation_id,
        descriptor: descriptor,
        dataset_guid: journal["dataset_guid"],
        expires_at: System.system_time(:second) + 180,
        source_endpoint: %{
          "address" => "source.example.test",
          "port" => 2222,
          "host_key" => public
        }
      }

      config = %{execution: execution, transfer_state_dir: root, pools: [pool], images: []}
      wire = OverallsProtocol.RelocationImport.encode_command(command)
      {:error, _} = Lilly.Transfer.Importer.adopt(config, Map.put(wire, "dataset_guid", "1"))

      if action == "adopt" do
        {:ok, guid} = Lilly.Transfer.Importer.adopt(config, wire)
        true = guid == journal["dataset_guid"]
        true = File.exists?(Path.join([execution.state_dir, placement, "vm.json"]))
        {:ok, nil} = Lilly.VM.Intent.read(Path.join(execution.state_dir, placement))
      else
        {:error, :import_intent_unconfirmed} = Lilly.Transfer.Importer.adopt(config, wire)
      end

      {:ok, %{state: "ready"}} = ZFSDataset.snapshot_claim(pool, placement)
      %{allocations: allocations} = Pool.report(pool)
      footprint = Spec.storage_bytes(spec)
      true = allocations[placement] > 0 and allocations[placement] <= footprint

    "reject-cancel-activated" ->
      execution = execution_config.()
      directory = Path.join(execution.state_dir, placement)
      {:ok, before} = Lilly.VM.Intent.read(directory)

      {:error, :destination_cleanup_unconfirmed} =
        Lilly.VM.Driver.retire_transfer_destination(
          execution,
          pool,
          spec,
          descriptor.destination_epoch,
          fn -> raise "must not reclaim an activated disk" end
        )

      {:ok, ^before} = Lilly.VM.Intent.read(directory)
      false = File.exists?(Path.join(directory, "deleted.json"))

    "activate-stopped" ->
      execution = execution_config.()

      :ok =
        Lilly.VM.Driver.stop(execution, pool, spec,
          execution_epoch: descriptor.destination_epoch,
          generation: 3
        )

      {:ok, %{state: :stopped, execution_epoch: epoch}} =
        Lilly.VM.Intent.read(Path.join(execution.state_dir, placement))

      true = epoch == descriptor.destination_epoch
      {:ok, :stopped} = Lilly.VM.Unit.status(spec)

    "reuse" ->
      image = load_image.()
      {:ok, _placement_lock} = Lilly.Host.Lock.acquire("/run/adoption-placement-" <> spec.id)

      # @cc [owner:ghuntley,label:verification] adoption-reuse-bounded-observation-retry
      # Reuse MUST succeed through the production preparation guards. Only
      # storage_busy may retry, with the same binding and a 30-second deadline;
      # other failures MUST remain failures and data checks MUST still run.
      deadline = System.monotonic_time(:millisecond) + 30_000

      prepare = fn retry ->
        case Disk.prepare(pool, image, spec) do
          {:error, :storage_busy} = error ->
            if System.monotonic_time(:millisecond) < deadline do
              Process.sleep(100)
              retry.(retry)
            else
              error
            end

          result ->
            result
        end
      end

      :ok = prepare.(prepare)

    "reject-prepare" ->
      image = load_image.()
      {:ok, _placement_lock} = Lilly.Host.Lock.acquire("/run/adoption-placement-" <> spec.id)
      {:error, _} = Disk.prepare(pool, image, spec)

    "reject-adopt" ->
      {:error, _} = Disk.adopt(pool, descriptor)
  end
end
