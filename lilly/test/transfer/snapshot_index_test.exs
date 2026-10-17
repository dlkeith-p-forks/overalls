defmodule Lilly.Transfer.SnapshotIndexTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.Transfer.{SnapshotIndex, SnapshotJournal}
  @moduletag :tmp_dir

  setup %{tmp_dir: metadata} do
    File.chmod!(metadata, 0o700)

    binding = %{
      host_id: Lilly.UUID.generate(),
      pool_id: Lilly.UUID.generate(),
      placement_id: Lilly.UUID.generate(),
      relocation_id: Lilly.UUID.generate(),
      zpool_guid: "100",
      parent_dataset_guid: "200",
      dataset_guid: "300",
      execution_epoch: 7
    }

    %{metadata: metadata, binding: binding}
  end

  defp locked(metadata, callback) do
    {:ok, lock} = Lock.acquire(metadata)

    try do
      callback.()
    after
      Lock.release(lock)
    end
  end

  defp next(binding),
    do: %{
      binding
      | relocation_id: Lilly.UUID.generate(),
        execution_epoch: binding.execution_epoch + 1
    }

  defp pointer_path(c), do: Path.join(c.metadata, "snapshot-current.json")

  defp retire(metadata, binding) do
    {:ok, current} = SnapshotIndex.begin_retire(metadata, binding)

    for {_name, slot} <- current.journal["snapshots"] do
      {:ok, _} = SnapshotJournal.deleted(current.directory, binding, slot["guid"])
    end

    {:ok, _} = SnapshotJournal.finish_retire(current.directory, binding)
  end

  test "the index selects a durable journal and retains retired history across moves", c do
    locked(c.metadata, fn ->
      assert {:ok, first} = SnapshotIndex.prepare(c.metadata, c.binding)
      assert {:ok, ^first} = SnapshotIndex.current(c.metadata)
      assert {:ok, ^first} = SnapshotIndex.prepare(c.metadata, c.binding)
      pointer = File.read!(pointer_path(c)) |> JSON.decode!()
      assert pointer["state"] == "bound"
      assert pointer["binding"]["placement_id"] == c.binding.placement_id
      assert Bitwise.band(File.stat!(pointer_path(c)).mode, 0o777) == 0o600
      retire(c.metadata, c.binding)
      {:ok, old} = SnapshotIndex.current(c.metadata)
      binding = next(c.binding)
      assert {:ok, second} = SnapshotIndex.prepare(c.metadata, binding)
      refute first.directory == second.directory
      assert File.exists?(Path.join(first.directory, "snapshots.json"))
      bytes = File.read!(pointer_path(c))
      assert {:ok, ^old} = SnapshotIndex.begin_retire(c.metadata, c.binding)
      assert File.read!(pointer_path(c)) == bytes
      assert {:ok, ^second} = SnapshotIndex.current(c.metadata)
      assert {:error, _} = SnapshotIndex.prepare(c.metadata, c.binding)
    end)
  end

  test "a competing relocation waits for retirement and needs a strictly newer epoch", c do
    locked(c.metadata, fn ->
      {:ok, first} = SnapshotIndex.prepare(c.metadata, c.binding)
      other = next(c.binding)
      assert {:error, _} = SnapshotIndex.prepare(c.metadata, other)
      assert {:error, _} = SnapshotIndex.begin_retire(c.metadata, other)
      assert {:ok, ^first} = SnapshotIndex.current(c.metadata)
      {:ok, _} = SnapshotIndex.begin_retire(c.metadata, c.binding)
      assert {:error, _} = SnapshotIndex.prepare(c.metadata, other)
      retire(c.metadata, c.binding)

      for epoch <- [6, 7] do
        assert {:error, _} =
                 SnapshotIndex.prepare(c.metadata, %{other | execution_epoch: epoch})
      end

      assert {:ok, _} = SnapshotIndex.prepare(c.metadata, other)
    end)
  end

  test "successive clones and a later relocation reuse the epoch only after retirement", c do
    locked(c.metadata, fn ->
      {:ok, first} = SnapshotIndex.prepare(c.metadata, c.binding, :clone)
      second = %{c.binding | relocation_id: Lilly.UUID.generate()}
      assert {:error, _} = SnapshotIndex.prepare(c.metadata, second, :clone)
      {:ok, retiring} = SnapshotIndex.begin_retire(c.metadata, c.binding, :clone)

      for {_name, slot} <- retiring.journal["snapshots"] do
        {:ok, _} = SnapshotJournal.deleted(retiring.directory, c.binding, slot["guid"])
      end

      {:ok, _} = SnapshotJournal.finish_retire(retiring.directory, c.binding)
      {:ok, next} = SnapshotIndex.prepare(c.metadata, second, :clone)
      refute next.directory == first.directory
      # A stale retired cleanup does not regress the pointer or erase new state.
      assert {:ok, _} = SnapshotIndex.begin_retire(c.metadata, c.binding, :clone)
      assert {:ok, ^next} = SnapshotIndex.current(c.metadata)
      assert {:error, _} = SnapshotIndex.prepare(c.metadata, c.binding, :clone)
      {:ok, retiring} = SnapshotIndex.begin_retire(c.metadata, second, :clone)
      {:ok, _} = SnapshotJournal.deleted(retiring.directory, second, nil)
      {:ok, _} = SnapshotJournal.finish_retire(retiring.directory, second)
      third = %{second | relocation_id: Lilly.UUID.generate()}
      assert {:ok, _} = SnapshotIndex.prepare(c.metadata, third)

      assert {:error, _} =
               SnapshotIndex.prepare(c.metadata, %{third | execution_epoch: 6}, :clone)
    end)
  end

  test "retirement cannot rebind native identities or reuse an earlier relocation ID", c do
    locked(c.metadata, fn ->
      retire(c.metadata, c.binding)
      newer = next(c.binding)

      for field <- [
            :host_id,
            :pool_id,
            :placement_id,
            :zpool_guid,
            :parent_dataset_guid,
            :dataset_guid
          ] do
        value =
          if field in [:host_id, :pool_id, :placement_id], do: Lilly.UUID.generate(), else: "999"

        assert {:error, _} =
                 SnapshotIndex.prepare(c.metadata, Map.put(newer, field, value))
      end

      assert {:error, _} =
               SnapshotIndex.prepare(c.metadata, %{c.binding | execution_epoch: 8})

      retire(c.metadata, newer)

      assert {:error, _} =
               SnapshotIndex.prepare(c.metadata, %{c.binding | execution_epoch: 9})
    end)
  end

  test "interruption after initial pointer publication resumes only that binding", c do
    locked(c.metadata, fn ->
      initial_pointer(c)
      assert {:error, _} = SnapshotIndex.current(c.metadata)
      assert {:error, _} = SnapshotIndex.prepare(c.metadata, next(c.binding))
      assert {:ok, current} = SnapshotIndex.prepare(c.metadata, c.binding)
      assert {:ok, ^current} = SnapshotIndex.current(c.metadata)
    end)
  end

  test "interruption after journal publication reuses its nonce before binding the pointer", c do
    locked(c.metadata, fn ->
      initial_pointer(c)
      parent = Path.join(c.metadata, "transfers")
      :ok = PrivateFiles.directory(parent)
      directory = Path.join(parent, c.binding.relocation_id)
      {:ok, journal} = SnapshotJournal.prepare(directory, c.binding)
      assert {:error, _} = SnapshotIndex.current(c.metadata)
      assert {:ok, current} = SnapshotIndex.prepare(c.metadata, c.binding)
      assert current.journal == journal
      assert current.directory == directory
    end)
  end

  test "a lost bound journal is never regenerated and lost pointers never reset retained history",
       c do
    locked(c.metadata, fn ->
      {:ok, current} = SnapshotIndex.prepare(c.metadata, c.binding)
      path = Path.join(current.directory, "snapshots.json")
      original = File.read!(path)
      File.rm!(path)
      assert {:error, _} = SnapshotIndex.current(c.metadata)
      assert {:error, _} = SnapshotIndex.prepare(c.metadata, c.binding)
      assert {:error, _} = SnapshotIndex.begin_retire(c.metadata, c.binding)
      refute File.exists?(path)
      :ok = PrivateFiles.write(current.directory, "snapshots.json", original)
      File.rm!(pointer_path(c))
      assert {:error, _} = SnapshotIndex.current(c.metadata)
      assert {:error, _} = SnapshotIndex.prepare(c.metadata, c.binding)
      assert {:error, _} = SnapshotIndex.prepare(c.metadata, next(c.binding))
      refute File.exists?(pointer_path(c))
    end)
  end

  test "unsafe or malformed index files are not overwritten", c do
    locked(c.metadata, fn ->
      {:ok, _} = SnapshotIndex.prepare(c.metadata, c.binding)
      original = File.read!(pointer_path(c)) |> JSON.decode!()

      for value <- [
            Map.put(original, "extra", true),
            %{original | "state" => "unknown"},
            put_in(original, ["binding", "relocation_id"], "../../foreign"),
            put_in(original, ["binding", "execution_epoch"], 0),
            put_in(original, ["binding", "dataset_guid"], "0300")
          ] do
        bytes = JSON.encode!(value)
        :ok = PrivateFiles.write(c.metadata, "snapshot-current.json", bytes)
        assert {:error, _} = SnapshotIndex.current(c.metadata)
        assert {:error, _} = SnapshotIndex.prepare(c.metadata, c.binding)
        assert File.read!(pointer_path(c)) == bytes
      end

      File.rm!(pointer_path(c))
      File.ln_s!("owner.lock", pointer_path(c))
      assert {:error, _} = SnapshotIndex.begin_retire(c.metadata, c.binding)
    end)
  end

  test "invalid input and missing locks or metadata create no index", c do
    assert {:error, _} = SnapshotIndex.prepare(c.metadata, c.binding)
    assert File.ls!(c.metadata) == []

    locked(c.metadata, fn ->
      for binding <- [
            nil,
            %{},
            Map.put(c.binding, {:unknown, :key}, true),
            %{c.binding | execution_epoch: 0}
          ] do
        assert {:error, _} = SnapshotIndex.prepare(c.metadata, binding)
      end

      assert {:error, _} = SnapshotIndex.prepare(c.metadata, c.binding, :unknown)
      missing = Path.join(c.metadata, "absent")
      assert {:error, _} = SnapshotIndex.prepare(missing, c.binding)
      refute File.exists?(missing)
      refute File.exists?(pointer_path(c))
    end)
  end

  defp initial_pointer(c) do
    binding = Map.new(c.binding, fn {key, value} -> {Atom.to_string(key), value} end)

    :ok =
      Lilly.Lifecycle.Journal.write(
        Lilly.Lifecycle.SnapshotPointer,
        c.metadata,
        "snapshot-current.json",
        %{
          "version" => 1,
          "state" => "initializing",
          "binding" => binding
        }
      )
  end
end
