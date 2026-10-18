defmodule Lilly.VM.JournalTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.VM.Journal
  @id "11111111-1111-4111-8111-111111111111"
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    {:ok, journal} = Journal.open(dir, @id, @id, @id)
    %{journal: journal}
  end

  @tag :hegel

  test "outcomes survive reopening and delayed receipts cannot discard newer state", %{
    journal: initial
  } do
    check all(count <- integer(1..8), max_runs: 15) do
      dir = Path.join(initial.directory, Lilly.UUID.generate())
      {:ok, journal} = Journal.open(dir, @id, @id, @id)

      last =
        Enum.reduce(1..count, journal, fn generation, previous ->
          command = command(generation)
          {:ok, next} = Journal.attempt(previous, command)
          {:ok, next} = Journal.record(next, command, running())
          assert next.sequence == generation

          if previous.outcome do
            {:ok, same} = Journal.acknowledge(next, [previous.outcome.id])
            assert Journal.pending(same) == next.outcome
          end

          {:ok, reloaded} = Journal.open(dir, @id, @id, @id)
          assert reloaded == next
          reloaded
        end)

      {:ok, acked} = Journal.acknowledge(last, [last.outcome.id])
      assert Journal.pending(acked) == nil
      {:ok, ^acked} = Journal.open(dir, @id, @id, @id)
      assert acked.running_generation == count
    end
  end

  test "execution attempts and outcomes advance beyond 64 transitions without diagnostics", %{
    journal: initial
  } do
    last =
      Enum.reduce(1..40, initial, fn generation, previous ->
        command = command(generation)
        assert {:ok, attempted} = Journal.attempt(previous, command)
        assert {:ok, recorded} = Journal.record(attempted, command, running())
        recorded
      end)

    assert {:ok, ^last} = Journal.open(initial.directory, @id, @id, @id)

    assert {:ok, %{revision: revision}} =
             Lilly.Lifecycle.Journal.load(
               Lilly.Lifecycle.Execution,
               initial.directory,
               "journal.json"
             )

    assert revision == 81

    assert {:ok, _, metadata} =
             initial.directory
             |> Path.join("journal.json")
             |> File.read!()
             |> Lilly.Lifecycle.Journal.envelope()

    assert metadata["version"] == 2
    refute Map.has_key?(metadata, "events")
  end

  test "duplicate physical facts preserve the event ID and sequence; stale work cannot commit", %{
    journal: journal
  } do
    command = command(1)
    {:ok, journal} = Journal.attempt(journal, command)
    {:ok, journal} = Journal.record(journal, command, running())
    assert {:ok, ^journal} = Journal.record(journal, command, running())
    {:ok, newer} = Journal.attempt(journal, command(2))
    assert {:error, :stale_generation} = Journal.record(newer, command, running())
    assert {:error, :stale_generation} = Journal.attempt(newer, command)
    refute newer.acknowledged
  end

  test "identity changes and corrupt persisted sequences fail closed", %{journal: journal} do
    assert {:error, :invalid_execution_journal} =
             Journal.open(journal.directory, Lilly.UUID.generate(), @id, @id)

    file = Path.join(journal.directory, "journal.json")
    body = File.read!(file) |> JSON.decode!() |> Map.put("sequence", 1)
    File.write!(file, JSON.encode!(body))
    assert {:error, :invalid_execution_journal} = Journal.open(journal.directory, @id, @id, @id)
  end

  test "unenveloped and near-miss journals fail closed without rewriting", %{journal: journal} do
    actor_locked(journal.directory, fn ->
      command = command(1)
      {:ok, journal} = Journal.attempt(journal, command)
      {:ok, journal} = Journal.record(journal, command, running())
      file = Path.join(journal.directory, "journal.json")
      {:ok, payload} = file |> File.read!() |> Lilly.Lifecycle.Journal.decode()

      for invalid <- [
            JSON.encode!(Map.delete(payload, "phase")),
            JSON.encode!(payload),
            file
            |> File.read!()
            |> JSON.decode!()
            |> Map.put("unexpected", true)
            |> JSON.encode!()
          ] do
        File.write!(file, invalid)

        assert {:error, :invalid_execution_journal} =
                 Journal.open(journal.directory, @id, @id, @id)

        assert File.read!(file) == invalid
      end
    end)
  end

  test "renewed authority rejects older epochs even with a higher generation", %{journal: journal} do
    old = command(100)
    {:ok, journal} = Journal.attempt(journal, old)
    {:ok, journal} = Journal.record(journal, old, running())
    fresh = %{command(1) | execution_epoch: 2}
    {:ok, journal} = Journal.attempt(journal, fresh)
    assert {:error, :stale_generation} = Journal.attempt(journal, %{old | generation: 1000})
    assert {:error, :stale_generation} = Journal.record(journal, old, running())
    assert journal.running_epoch == 1
    {:ok, journal} = Journal.record(journal, fresh, running())
    assert journal.running_epoch == 2
    assert journal.running_generation == 1
    assert journal.sequence == 2
    assert {:ok, ^journal} = Journal.open(journal.directory, @id, @id, @id)
  end

  test "a different placement cannot reuse a journal or publish its outcomes", %{journal: journal} do
    other = Lilly.UUID.generate()
    assert {:error, :invalid_execution_journal} = Journal.open(journal.directory, @id, @id, other)

    assert {:error, :vm_identity_conflict} =
             Journal.attempt(journal, %{command(1) | placement_id: other})

    {:ok, journal} = Journal.attempt(journal, command(1))

    assert {:error, :stale_generation} =
             Journal.record(journal, %{command(1) | placement_id: other}, running())
  end

  test "uncertain deletion can confirm on retry without changing its generation", %{
    journal: journal
  } do
    command = %{command(1) | kind: :delete}
    {:ok, journal} = Journal.attempt(journal, command)

    {:ok, journal} =
      Journal.record(journal, command, %{running() | state: :unknown, reason: :unknown})

    {:ok, journal} = Journal.attempt(journal, command)

    deleted = %{
      running()
      | state: :deleted,
        disk_present: false,
        compute_empty: true,
        cleanup_complete: true
    }

    assert {:ok, journal} = Journal.record(journal, command, deleted)
    assert journal.phase == "deleted"
    assert {:ok, ^journal} = Journal.open(journal.directory, @id, @id, @id)
    assert {:error, _} = Journal.attempt(journal, command(2))
  end

  defp running,
    do: %{
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

  defp actor_locked(directory, callback) do
    {:ok, lock} = Lilly.Host.Lock.acquire(directory)

    try do
      callback.()
    after
      Lilly.Host.Lock.release(lock)
    end
  end

  defp command(generation),
    do: %{
      id: "00000000-0000-4000-8000-" <> String.pad_leading(to_string(generation), 12, "0"),
      vm_id: @id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: generation,
      kind: :start,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }
end
