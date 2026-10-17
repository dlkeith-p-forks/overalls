defmodule ZFSGuestRestorationFixture do
  @moduledoc false
  alias Lilly.Host.{Pool, Storage, ZFS, ZFSDataset}
  alias Lilly.Transfer.{SnapshotIndex, SourceRevocation, SourceSnapshotCleanup}
  alias Lilly.VM.{Boot, Driver, Observation}

  # @cc [owner:ghuntley,label:verification] cancelled-source-native-restoration
  # This fixture MUST restart the retained source under a fresh epoch only after
  # typed export revocation and physical stop. With a snapshot, the source is first
  # physically stopped for its single full copy (ADR-0155), as a relocation stop
  # would. It MUST verify a new ready boot, unchanged disk/snapshot GUIDs before
  # cleanup, stale launch rejection, and snapshot-only cleanup while the restored
  # guest remains running. Synthetic control MUST NOT establish Marshall
  # coordination or destination reclamation.
  def run(config, pool, image, spec, snapshot? \\ true) do
    Code.require_file("/etc/zfs-source.exs")
    directory = Path.join(config.state_dir, spec.id)
    {:ok, old_boot} = Boot.read(directory)
    {:ok, old_guest} = Driver.ready_boot(config, pool, spec, execution_epoch: 1, generation: 1)

    if snapshot? do
      :ok = Driver.stop(config, pool, spec, execution_epoch: 1, generation: 2)
      :ok = ZFSGuestSourceFixture.run(config, pool, spec, 2, "source-full")
    else
      :ok = ZFSGuestSourceFixture.run(config, pool, spec, 1, "source-reject")
    end

    {:ok, before} = snapshots(pool, spec)
    relocation = "ffffffff-ffff-4fff-8fff-" <> String.slice(spec.id, -12, 12)
    true = if snapshot?, do: before != nil, else: before == nil
    {:ok, claim} = Storage.locked(pool, fn -> ZFSDataset.snapshot_source(pool, spec) end)

    request = %{
      id: relocation,
      host_id: pool.host_id,
      placement_id: spec.id,
      execution_epoch: 1,
      expires_at: System.system_time(:second) + 180
    }

    {:ok, receipt} = SourceRevocation.execute("/var/lib/lilly/transfers", pool.host_id, request)
    {:ok, ^receipt} = SourceRevocation.execute("/var/lib/lilly/transfers", pool.host_id, request)
    :ok = Driver.stop(config, pool, spec, execution_epoch: 2, generation: 2)
    false = Observation.running?(config, pool, spec)
    {:ok, ^before} = snapshots(pool, spec)
    :ok = start_restored(config, pool, image, spec, System.monotonic_time(:millisecond) + 30_000)
    running(config, pool, spec, System.monotonic_time(:millisecond) + 30_000)
    {:ok, new_guest} = Driver.ready_boot(config, pool, spec, execution_epoch: 2, generation: 3)
    {:ok, new_boot} = Boot.read(directory)
    true = new_guest != old_guest and new_boot.boot_challenge != old_boot.boot_challenge
    true = new_boot.execution_epoch == 2 and new_boot.generation == 3
    {:ok, ^before} = snapshots(pool, spec)

    {:error, _} = Driver.start(config, pool, image, spec, execution_epoch: 1, generation: 99)
    {:ok, ^new_guest} = Driver.ready_boot(config, pool, spec, execution_epoch: 2, generation: 3)

    :ok = cleanup(config, pool, spec, %{request | expires_at: System.system_time(:second) + 180})
    {:ok, retired} = snapshots(pool, spec)

    true =
      retired.binding.dataset_guid == claim.dataset_guid and retired.journal["phase"] == "retired"

    true = retired.binding.relocation_id == relocation and retired.binding.execution_epoch == 1
    true = Enum.all?(retired.journal["snapshots"], fn {_, slot} -> slot["state"] == "deleted" end)
    {:ok, ^new_boot} = Boot.read(directory)
    {:ok, ^new_guest} = Driver.ready_boot(config, pool, spec, execution_epoch: 2, generation: 3)
    :ok
  end

  # @cc [owner:ghuntley,label:verification] logical-delete-snapshot-retry
  # A stopped source with its relocation snapshot MUST remain deletion-fenced
  # after ordinary Delete reports incomplete reclamation. Authenticated snapshot
  # cleanup MUST permit the same Delete revision to finish without a restart;
  # stale launches remain refused and native disk absence is checked by the driver.
  def delete_source(config, pool, image, spec) do
    Code.require_file("/etc/zfs-source.exs")
    :ok = Driver.stop(config, pool, spec, execution_epoch: 1, generation: 2)
    :ok = ZFSGuestSourceFixture.run(config, pool, spec, 2, "source-full")
    {:ok, before} = snapshots(pool, spec)
    true = before != nil
    {:error, _} = Driver.delete(config, pool, spec, execution_epoch: 1, generation: 3)
    {:ok, :stopped} = Lilly.VM.Unit.status(spec)

    {:ok, %{state: :deleted, execution_epoch: 1, generation: 3}} =
      Lilly.VM.Intent.read(Path.join(config.state_dir, spec.id))

    {:error, _} = Driver.start(config, pool, image, spec, execution_epoch: 1, generation: 99)

    request = %{
      id: before.binding.relocation_id,
      host_id: pool.host_id,
      placement_id: spec.id,
      execution_epoch: 1,
      expires_at: System.system_time(:second) + 180
    }

    :ok = cleanup(config, pool, spec, request, :delete, 1, 3)
    {:ok, retired} = snapshots(pool, spec)
    true = retired.journal["phase"] == "retired"
    :ok = Driver.delete(config, pool, spec, execution_epoch: 1, generation: 3)
    :ok = Driver.delete(config, pool, spec, execution_epoch: 1, generation: 3)
    {:error, _} = Driver.start(config, pool, image, spec, execution_epoch: 1, generation: 100)
    :ok
  end

  defp cleanup(config, pool, spec, request, kind \\ :start, epoch \\ 2, generation \\ 3) do
    alias Lilly.Control.{Client, Store}
    alias Lilly.Host.Lock
    state = "/var/lib/lilly/source-control"
    {:ok, lock} = Lock.acquire(state)

    try do
      {:ok, store} = Store.open(state, pool.host_id)
      {:ok, old} = Store.read(store, spec.id)

      command = %{
        old
        | id: Lilly.UUID.generate(),
          execution_epoch: epoch,
          generation: generation,
          kind: kind
      }

      {:ok, _} = Store.accept(store, command)

      runtime = %Lilly.Control.Config{
        client: %Client{
          host_id: pool.host_id,
          base_url: "https://fixture.invalid",
          token: "unused"
        },
        state_dir: state,
        cgroup_path: "/sys/fs/cgroup/lilly.slice",
        pools: [pool],
        execution: config,
        transfer_state_dir: "/var/lib/lilly/transfers"
      }

      Task.async(fn ->
        for bad <- [
              %{request | execution_epoch: 2},
              %{request | expires_at: System.system_time(:second) - 1}
            ] do
          {:error, _} = SourceSnapshotCleanup.execute(runtime, store, bad)
        end

        {:ok, receipt} = SourceSnapshotCleanup.execute(runtime, store, request)
        {:ok, ^receipt} = SourceSnapshotCleanup.execute(runtime, store, request)
        :ok
      end)
      |> Task.await(300_000)
    after
      Lock.release(lock)
    end
  end

  defp snapshots(pool, spec) do
    Storage.locked(pool, fn ->
      {:ok, claim} = ZFSDataset.snapshot_source(pool, spec)
      {:ok, current} = SnapshotIndex.current(ZFSDataset.metadata_directory(pool, spec))
      true = current == nil or claim.dataset_guid == current.binding.dataset_guid
      {:ok, owners} = ZFS.owners(Pool.zfs_identity(pool))

      slots = if current, do: current.journal["snapshots"], else: %{}

      Enum.each(slots, fn {suffix, slot} ->
        native = owners[ZFSDataset.name(pool, spec) <> "@" <> suffix]

        if slot["state"] == "deleted",
          do: true = is_nil(native),
          else: true = is_map(native) and native["guid"] == slot["guid"]
      end)

      {:ok, current}
    end)
  end

  # Retry only pre-launch pool-lock contention, preserving the exact new fence.
  # All other errors and an exhausted deadline remain test failures.
  defp start_restored(config, pool, image, spec, deadline) do
    case Driver.start(config, pool, image, spec, execution_epoch: 2, generation: 3) do
      {:error, :storage_busy} = result ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          start_restored(config, pool, image, spec, deadline)
        else
          result
        end

      result ->
        result
    end
  end

  defp running(config, pool, spec, deadline) do
    unless Observation.running?(config, pool, spec) do
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("Restored source VMM did not become observable")

      Process.sleep(100)
      running(config, pool, spec, deadline)
    end
  end
end
