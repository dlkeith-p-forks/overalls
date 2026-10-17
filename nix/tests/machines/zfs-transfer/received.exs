# @cc [owner:ghuntley,label:verification] received-dataset-native-scope
# This fixture MUST use source-built Lilly against real received ZFS state and
# destination-local journals. Its synthetic descriptor is not a bootable-image or
# guest-rootfs validation fixture; success MUST NOT be reported as activation.
alias Lilly.Host.{Command, Pool, ZFS, ZFSDataset}
alias Lilly.Transfer.ReceivedDataset
alias OverallsProtocol.{Relocation, Storage}

host = "aaaaaaaa-aaaa-4aaa-8aaa-000000000002"
pool_id = "bbbbbbbb-bbbb-4bbb-8bbb-000000000002"
mode = System.fetch_env!("RECEIVED_MODE")

number = %{"partial" => 6, "empty" => 8}[mode] || 2
placement = "dddddddd-dddd-4ddd-8ddd-" <> String.pad_leading(to_string(number), 12, "0")

descriptor_path = "/run/received-" <> mode <> ".json"

{:ok, identity} = ZFS.inspect_path("/import-pool")

{:ok, pool} =
  Pool.new(pool_id, identity.path, identity.filesystem_id,
    host_id: host,
    storage: Storage.encode(identity.storage)
  )

action = System.fetch_env!("RECEIVED_ACTION")

if action == "prepare" do
  {:ok, source_guid} = Command.run(:zfs_get, ["-Hp", "-o", "value", "guid", "source/workload"])

  {:ok, snapshot_guid} =
    Command.run(:zfs_get, ["-Hp", "-o", "value", "guid", "source/workload@lilly-b"])

  {:ok, descriptor} =
    Relocation.descriptor(%{
      "version" => 3,
      "relocation_id" => "ffffffff-ffff-4fff-8fff-000000000001",
      "vm_id" => "eeeeeeee-eeee-4eee-8eee-000000000001",
      "source" => %{
        "placement_id" => "dddddddd-dddd-4ddd-8ddd-000000000001",
        "host_id" => "aaaaaaaa-aaaa-4aaa-8aaa-000000000001",
        "pool_id" => "bbbbbbbb-bbbb-4bbb-8bbb-000000000001"
      },
      "destination" => %{"placement_id" => placement, "host_id" => host, "pool_id" => pool_id},
      "source_epoch" => 1,
      "destination_epoch" => 2,
      "workload" => %{
        "image_id" => "sha256:" <> String.duplicate("a", 64),
        "architecture" => "x86_64",
        "profile" => "customer",
        "slot" => 2,
        "vcpu" => 1,
        "memory_bytes" => 536_870_912,
        "disk_bytes" => 2_147_483_648
      },
      "stream" => %{
        "source_dataset_guid" => String.trim(source_guid),
        "to_guid" => String.trim(snapshot_guid)
      }
    })

  {:ok, _} =
    Lilly.Host.Storage.locked(pool, fn ->
      {:ok, first} = ReceivedDataset.prepare(pool, descriptor)
      {:ok, ^first} = ReceivedDataset.prepare(pool, descriptor)
    end)

  File.write!(descriptor_path, JSON.encode!(Relocation.encode_descriptor(descriptor)))
else
  {:ok, descriptor} = File.read!(descriptor_path) |> JSON.decode!() |> Relocation.descriptor()

  result =
    Lilly.Host.Storage.locked(pool, fn ->
      case action do
        "resume" ->
          {:error, :received_dataset_unconfirmed} =
            ReceivedDataset.fresh_receiver(pool, descriptor)

          # Keep opaque tokens out of MatchError and console diagnostics.
          fetched = ReceivedDataset.resume_token(pool, descriptor)
          true = match?({:ok, value} when is_binary(value), fetched)
          token = elem(fetched, 1)
          true = ReceivedDataset.resume_token(pool, descriptor) == {:ok, token}

          :ok =
            Lilly.Transfer.ResumeToken.validate(
              "source/workload@lilly-b",
              descriptor.stream,
              token
            )

          altered = put_in(descriptor.stream.to_guid, "1")
          {:error, :received_dataset_unconfirmed} = ReceivedDataset.resume_token(pool, altered)
          name = pool.storage.dataset <> "/vm-" <> placement
          {:error, :zfs_resume_unconfirmed} = ZFS.resume_child(identity, name, "1", %{})

          {:ok, record} =
            Lilly.Transfer.ImportJournal.read(
              ReceivedDataset.directory(pool, placement),
              descriptor,
              pool.storage
            )

          "active" = record["phase"]
          "receiving" = record["stream_state"]
          true = Storage.guid?(record["dataset_guid"])
          false = File.exists?(Path.join([pool.path, ".lilly-zfs", "active", placement]))
          :ok

        "reject-resume" ->
          ReceivedDataset.resume_token(pool, descriptor)

        "receiver" ->
          ReceivedDataset.receiver(pool, descriptor)

        value when value in ["cleanup", "reject-cleanup"] ->
          if mode == "empty" do
            Lilly.Transfer.ImportCleanup.cleanup(pool, descriptor)
          else
            Lilly.Transfer.ImportCleanup.cleanup_intent(pool, Map.delete(descriptor, :stream))
          end

        "cleanup-absent" ->
          :ok = Lilly.Transfer.ImportCleanup.cleanup_intent(pool, Map.delete(descriptor, :stream))

          {:ok, nil} =
            Lilly.Transfer.ImportJournal.for_intent(
              ReceivedDataset.directory(pool, placement),
              Map.delete(descriptor, :stream),
              pool.storage
            )

          :ok

        "reject-import" ->
          ReceivedDataset.prepare(pool, descriptor)

        "reject-bind" ->
          ZFSDataset.bind(pool)

        "reject-prepare" ->
          {:ok, spec} =
            descriptor.workload
            |> Map.drop([:architecture])
            |> Map.merge(%{id: placement, pool_id: pool.id})
            |> Lilly.VM.Spec.new()

          ZFSDataset.prepare(pool, spec)

        "reject-adopt" ->
          {:ok, spec} =
            descriptor.workload
            |> Map.drop([:architecture])
            |> Map.merge(%{id: placement, pool_id: pool.id})
            |> Lilly.VM.Spec.new()

          ZFSDataset.adopt(pool, spec, descriptor)

        _ ->
          ReceivedDataset.verify(pool, descriptor)
      end
    end)

  if action == "receiver" do
    {:ok, {executable, arguments}} = result
    path = "/run/receiver-" <> mode <> ".json"
    File.write!(path, JSON.encode!([executable | arguments]))
    File.chmod!(path, 0o600)
  else
    if action == "cleanup" do
      if result != :ok do
        # Failure diagnostics contain native identity/policy only, never resume tokens,
        # ownership nonces, credentials or guest data.
        {:ok, record} =
          Lilly.Transfer.ImportJournal.read(
            ReceivedDataset.directory(pool, placement),
            descriptor,
            pool.storage
          )

        IO.inspect(Map.take(record, ["phase", "dataset_guid", "stream_state"]),
          label: "cleanup state"
        )

        {:ok, rows} =
          Command.run(:zfs_list, [
            "-Hpr",
            "-t",
            "all",
            "-o",
            "name,guid,used,usedbydataset,usedbychildren,usedbysnapshots,readonly,canmount,mounted",
            pool.storage.dataset
          ])

        IO.puts(rows)
      end

      :ok = result

      {:ok, %{"phase" => "retired"}} =
        Lilly.Transfer.ImportJournal.read(
          ReceivedDataset.directory(pool, placement),
          descriptor,
          pool.storage
        )
    else
      if action in ["cleanup-absent", "resume"] do
        :ok = result
      else
        if action == "verify" do
          {:ok, journal} = result
          "received" = journal["stream_state"]
          true = journal["dataset_guid"] != descriptor.stream.source_dataset_guid
          false = File.exists?(Path.join([pool.path, ".lilly-zfs", "active", placement]))
          # Staging is not ordinary allocation credit or an executable disk claim.
          %{unavailable: true} = Pool.report(pool)
        else
          true =
            action in [
              "reject",
              "reject-bind",
              "reject-prepare",
              "reject-import",
              "reject-adopt",
              "reject-cleanup",
              "reject-resume"
            ]

          {:error, _} = result
        end
      end
    end
  end
end
