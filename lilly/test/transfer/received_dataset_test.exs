defmodule Lilly.Transfer.ReceivedDatasetTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.{Lock, Pool, ZFSDataset}
  alias Lilly.Transfer.ReceivedDataset
  alias Lilly.Transfer.ImportCleanup
  @moduletag :tmp_dir

  test "missing local intent fails before native effects or ownership creation", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)

    pool = %Pool{
      id: Lilly.UUID.generate(),
      host_id: Lilly.UUID.generate(),
      path: dir,
      filesystem_id: "zfs:1:2",
      storage: %{backend: :zfs, zpool_guid: "1", dataset_guid: "2", dataset: "target/lilly"}
    }

    destination = %{host_id: pool.host_id, pool_id: pool.id, placement_id: Lilly.UUID.generate()}

    descriptor = %{
      relocation_id: Lilly.UUID.generate(),
      vm_id: Lilly.UUID.generate(),
      destination: destination,
      source: %{
        host_id: Lilly.UUID.generate(),
        pool_id: Lilly.UUID.generate(),
        placement_id: Lilly.UUID.generate()
      },
      source_epoch: 1,
      destination_epoch: 2,
      workload: %{
        image_id: "sha256:" <> String.duplicate("a", 64),
        architecture: :x86_64,
        profile: :customer,
        slot: 2,
        vcpu: 1,
        memory_bytes: 536_870_912,
        disk_bytes: 2_147_483_648
      },
      stream: %{source_dataset_guid: "3", to_guid: "4"}
    }

    assert {:error, :received_dataset_unconfirmed} = ReceivedDataset.verify(pool, descriptor)
    assert {:error, :received_dataset_unconfirmed} = ReceivedDataset.prepare(pool, descriptor)

    assert {:error, :received_dataset_unconfirmed} =
             ReceivedDataset.resume_token(pool, descriptor)

    assert {:error, :received_dataset_unconfirmed} = ReceivedDataset.receiver(pool, descriptor)
    assert {:error, :import_cleanup_unconfirmed} = ImportCleanup.cleanup(pool, descriptor)

    assert {:error, :import_cleanup_unconfirmed} =
             ImportCleanup.cleanup_intent(pool, Map.delete(descriptor, :stream))

    {:ok, spec} =
      descriptor.workload
      |> Map.drop([:architecture])
      |> Map.merge(%{id: destination.placement_id, pool_id: pool.id})
      |> Lilly.VM.Spec.new()

    assert {:error, :zfs_import_adoption_unconfirmed} = ZFSDataset.adopt(pool, spec, descriptor)
    {:ok, lock} = Lock.acquire(dir)

    try do
      assert {:error, :received_dataset_unconfirmed} = ReceivedDataset.receiver(pool, descriptor)
      assert {:error, :zfs_import_adoption_unconfirmed} = ZFSDataset.adopt(pool, spec, descriptor)

      for value <- [
            nil,
            descriptor,
            %{descriptor | destination: %{destination | host_id: Lilly.UUID.generate()}}
          ] do
        assert {:error, :received_dataset_unconfirmed} = ReceivedDataset.verify(pool, value)
      end

      for value <- [
            nil,
            %{},
            %{descriptor | stream: %{}},
            %{descriptor | destination: %{destination | host_id: Lilly.UUID.generate()}}
          ] do
        assert {:error, :received_dataset_unconfirmed} = ReceivedDataset.prepare(pool, value)
        assert {:error, :received_dataset_unconfirmed} = ReceivedDataset.receiver(pool, value)
        assert {:error, :received_dataset_unconfirmed} = ReceivedDataset.resume_token(pool, value)

        assert {:error, :received_dataset_unconfirmed} =
                 ReceivedDataset.fresh_receiver(pool, value)

        assert {:error, :import_cleanup_unconfirmed} = ImportCleanup.cleanup(pool, value)
      end

      refute File.exists?(Path.join(dir, ".lilly-zfs"))
      intent = Map.delete(descriptor, :stream)

      for value <- [
            nil,
            %{},
            descriptor,
            put_in(intent, [:destination, :placement_id], "../other"),
            put_in(intent, [:destination, :host_id], Lilly.UUID.generate()),
            Map.put(intent, :stream, nil)
          ] do
        assert {:error, :import_cleanup_unconfirmed} = ImportCleanup.cleanup_intent(pool, value)
      end

      refute File.exists?(Path.join(dir, ".lilly-zfs"))
      assert_raise MatchError, fn -> ReceivedDataset.directory(pool, "../other") end
    after
      Lock.release(lock)
    end
  end
end
