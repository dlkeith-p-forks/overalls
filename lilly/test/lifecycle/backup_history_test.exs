defmodule Lilly.Lifecycle.BackupHistoryTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Lock
  alias Lilly.Lifecycle.{BackupHistory, BackupSnapshot, Journal}
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    %{directory: directory, host: Lilly.UUID.generate(), placement: Lilly.UUID.generate()}
  end

  test "backup reads reject another resource envelope with otherwise valid backup fields", c do
    pool = %Lilly.Host.Pool{
      id: Lilly.UUID.generate(),
      path: c.directory,
      filesystem_id: "zfs:1:2",
      host_id: c.host,
      storage: %{backend: :zfs, dataset: "tank/lilly", zpool_guid: "1", dataset_guid: "2"}
    }

    directory = Path.join(Lilly.Host.ZFSDataset.ownership_directory(pool), c.placement)
    File.mkdir_p!(Path.dirname(directory))
    File.chmod!(Path.dirname(directory), 0o700)

    value = %{
      "version" => 1,
      "host_id" => c.host,
      "pool_id" => pool.id,
      "zpool_guid" => "1",
      "parent_dataset_guid" => "2",
      "placement_id" => c.placement,
      "dataset_guid" => "3",
      "run_id" => Lilly.UUID.generate(),
      "nonce" => String.duplicate("a", 64),
      "snapshot_guid" => nil,
      "phase" => "creating"
    }

    locked(directory, fn ->
      assert :ok = Journal.write(Lilly.Lifecycle.Dataset, directory, "backup.json", value)
      bytes = File.read!(Path.join(directory, "backup.json"))

      assert {:error, :backup_snapshot_unconfirmed} =
               Lilly.Host.BackupSnapshot.read(pool, c.placement)

      assert File.read!(Path.join(directory, "backup.json")) == bytes
    end)
  end

  test "offline recurring backups retain eighty committed transitions across stable run identities",
       c do
    records =
      locked(c.directory, fn ->
        Enum.map(1..20, fn _ ->
          assert {:ok, previous} = Journal.load(BackupSnapshot, c.directory, "backup.json")
          assert :ok = BackupHistory.prepare(c.directory, if(previous, do: previous.payload))
          payload = payload(c)

          for phase <- ~w(creating ready cleaning cleaned),
              do:
                assert(
                  :ok ==
                    Journal.write(BackupSnapshot, c.directory, "backup.json", %{
                      payload
                      | "phase" => phase
                    })
                )

          {:ok, record} = Journal.load(BackupSnapshot, c.directory, "backup.json")
          record
        end)
      end)

    assert length(Enum.uniq_by(records, & &1.id)) == 20
    assert Enum.sum(Enum.map(records, & &1.revision)) == 80

    assert {:ok, %{state: :cleaned, revision: 4}} =
             Journal.load(BackupSnapshot, c.directory, "backup.json")

    assert length(archives(c.directory)) == 19
  end

  test "interruption after archival retains old identities independently from a new run",
       c do
    old = locked(c.directory, fn -> finish(c) end)

    new =
      locked(c.directory, fn ->
        assert :ok = BackupHistory.prepare(c.directory, old.payload)
        assert {:ok, nil} = Journal.load(BackupSnapshot, c.directory, "backup.json")
        assert :ok = BackupHistory.prepare(c.directory, nil)
        assert :ok = Journal.write(BackupSnapshot, c.directory, "backup.json", payload(c))
        {:ok, record} = Journal.load(BackupSnapshot, c.directory, "backup.json")
        record
      end)

    refute new.id == old.id
    assert {:ok, ^new} = Journal.load(BackupSnapshot, c.directory, "backup.json")
    [archive] = archives(c.directory)
    assert {:ok, retained} = Journal.load(BackupSnapshot, c.directory, archive)
    assert retained.id == old.id and retained.payload == old.payload
    assert retained.revision == old.revision
  end

  test "active or corrupt journals cannot be archived or replaced", c do
    locked(c.directory, fn ->
      value = payload(c)
      assert :ok = Journal.write(BackupSnapshot, c.directory, "backup.json", value)
      bytes = File.read!(Path.join(c.directory, "backup.json"))
      assert {:error, _} = BackupHistory.prepare(c.directory, value)
      assert File.read!(Path.join(c.directory, "backup.json")) == bytes
      assert archives(c.directory) == []
      File.write!(Path.join(c.directory, "backup.json"), "corrupt")
      assert {:error, _} = BackupHistory.prepare(c.directory, nil)
      assert File.read!(Path.join(c.directory, "backup.json")) == "corrupt"
    end)
  end

  test "expiry removes at most sixteen old terminal archives and retains other evidence", c do
    locked(c.directory, fn ->
      now = System.system_time(:microsecond)
      old_time = now - 91 * 86_400 * 1_000_000

      for _ <- 1..20 do
        record = finish(c)
        assert :ok = BackupHistory.prepare(c.directory, record.payload)
      end

      old =
        Enum.map(archives(c.directory), fn name ->
          <<"backup-", _::binary-size(20), suffix::binary>> = name

          expired =
            "backup-" <> String.pad_leading(Integer.to_string(old_time), 20, "0") <> suffix

          File.rename!(Path.join(c.directory, name), Path.join(c.directory, expired))
          expired
        end)

      assert :ok = Journal.write(BackupSnapshot, c.directory, "backup.json", payload(c))
      active = File.read!(Path.join(c.directory, "backup.json"))
      File.write!(Path.join(c.directory, "claim.json"), "retained native evidence")

      corrupt =
        "backup-" <>
          String.pad_leading(Integer.to_string(old_time), 20, "0") <>
          "-" <> Lilly.UUID.generate() <> ".json"

      File.write!(Path.join(c.directory, corrupt), "corrupt")
      File.chmod!(Path.join(c.directory, corrupt), 0o600)
      {:ok, active_record} = Journal.load(BackupSnapshot, c.directory, "backup.json")

      active_archive =
        "backup-" <>
          String.pad_leading(Integer.to_string(old_time), 20, "0") <>
          "-" <> active_record.id <> ".json"

      File.write!(Path.join(c.directory, active_archive), active)
      File.chmod!(Path.join(c.directory, active_archive), 0o600)
      refute BackupHistory.exportable?(hd(old))

      assert :ok = BackupHistory.expire(c.directory, now)
      remaining = Enum.count(old, &File.exists?(Path.join(c.directory, &1)))
      assert remaining in 4..6
      assert :ok = BackupHistory.expire(c.directory, now)
      refute Enum.any?(old, &File.exists?(Path.join(c.directory, &1)))
      assert File.read!(Path.join(c.directory, corrupt)) == "corrupt"
      assert File.read!(Path.join(c.directory, active_archive)) == active
      assert File.read!(Path.join(c.directory, "backup.json")) == active
      assert File.read!(Path.join(c.directory, "claim.json")) == "retained native evidence"
    end)
  end

  property "native backup histories cannot skip cleanup or resurrect a cleaned producer", c do
    check all(
            targets <- list_of(member_of(~w(creating ready cleaning cleaned)), max_length: 15),
            max_runs: 20
          ) do
      directory = Path.join(c.directory, Lilly.UUID.generate())

      locked(directory, fn ->
        value = payload(c)
        assert :ok = Journal.write(BackupSnapshot, directory, "backup.json", value)

        Enum.reduce(targets, "creating", fn target, state ->
          allowed =
            case state do
              "creating" -> target in ~w(creating ready cleaning)
              "ready" -> target in ~w(ready cleaning)
              "cleaning" -> target in ~w(cleaning cleaned)
              "cleaned" -> target == "cleaned"
            end

          assert Journal.write(BackupSnapshot, directory, "backup.json", %{
                   value
                   | "phase" => target
                 }) == :ok == allowed

          {:ok, record} = Journal.load(BackupSnapshot, directory, "backup.json")
          expected = if allowed, do: target, else: state
          assert Atom.to_string(record.state) == expected
          expected
        end)
      end)
    end
  end

  defp finish(c) do
    value = payload(c)

    for phase <- ~w(creating ready cleaning cleaned),
        do:
          assert(
            :ok ==
              Journal.write(BackupSnapshot, c.directory, "backup.json", %{
                value
                | "phase" => phase
              })
          )

    {:ok, record} = Journal.load(BackupSnapshot, c.directory, "backup.json")
    record
  end

  defp payload(c),
    do: %{
      "phase" => "creating",
      "host_id" => c.host,
      "placement_id" => c.placement,
      "run_id" => Lilly.UUID.generate()
    }

  defp archives(directory),
    do: File.ls!(directory) |> Enum.filter(&String.starts_with?(&1, "backup-"))

  defp locked(directory, fun) do
    {:ok, lock} = Lock.acquire(directory)

    try do
      fun.()
    after
      Lock.release(lock)
    end
  end
end
