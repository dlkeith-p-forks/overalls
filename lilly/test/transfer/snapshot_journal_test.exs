defmodule Lilly.Transfer.SnapshotJournalTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.Transfer.SnapshotJournal, as: Journal
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)

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

    %{directory: directory, binding: binding}
  end

  defp locked(directory, callback) do
    {:ok, lock} = Lock.acquire(directory)

    try do
      callback.()
    after
      Lock.release(lock)
    end
  end

  test "the single slot is the stopped transfer snapshot name" do
    assert Journal.slot() == "lilly-b"
  end

  test "creation intent survives retries and binds one GUID once", c do
    locked(c.directory, fn ->
      assert {:ok, first} = Journal.prepare(c.directory, c.binding)
      assert {:ok, ^first} = Journal.read(c.directory, c.binding)
      assert {:ok, ^first} = Journal.prepare(c.directory, c.binding)
      assert Map.keys(first["snapshots"]) == ["lilly-b"]

      assert Bitwise.band(File.stat!(Path.join(c.directory, "snapshots.json")).mode, 0o777) ==
               0o600

      nonce = first["snapshots"]["lilly-b"]["nonce"]
      assert byte_size(nonce) == 32
      assert {:error, _} = Journal.expectations(c.directory, c.binding)
      assert {:error, _} = Journal.bind(c.directory, c.binding, "wrong", "500")
      assert {:ok, ready} = Journal.bind(c.directory, c.binding, nonce, "500")
      assert {:ok, ^ready} = Journal.bind(c.directory, c.binding, nonce, "500")
      assert {:error, _} = Journal.bind(c.directory, c.binding, nonce, "501")
      assert {:ok, ^ready} = Journal.prepare(c.directory, c.binding)

      assert {:ok, %{"lilly-b" => %{dataset_guid: "300", snapshot_guid: "500"}} = expected} =
               Journal.expectations(c.directory, c.binding)

      assert map_size(expected) == 1
    end)
  end

  test "retirement fences creation and retains the GUID until exact absence confirmation", c do
    locked(c.directory, fn ->
      {:ok, state} = Journal.prepare(c.directory, c.binding)
      nonce = state["snapshots"]["lilly-b"]["nonce"]
      {:ok, _} = Journal.bind(c.directory, c.binding, nonce, "500")

      assert {:error, _} = Journal.deleted(c.directory, c.binding, "500")
      assert {:error, _} = Journal.finish_retire(c.directory, c.binding)
      assert {:ok, state} = Journal.begin_retire(c.directory, c.binding)
      assert {:ok, ^state} = Journal.begin_retire(c.directory, c.binding)
      assert {:error, _} = Journal.prepare(c.directory, c.binding)
      assert {:error, _} = Journal.deleted(c.directory, c.binding, "999")
      assert {:error, _} = Journal.deleted(c.directory, c.binding, nil)
      assert {:ok, %{"lilly-b" => _}} = Journal.expectations(c.directory, c.binding)
      assert {:error, _} = Journal.finish_retire(c.directory, c.binding)
      assert {:ok, deleted} = Journal.deleted(c.directory, c.binding, "500")
      assert {:ok, ^deleted} = Journal.deleted(c.directory, c.binding, "500")
      assert {:ok, retired} = Journal.finish_retire(c.directory, c.binding)
      assert {:ok, ^retired} = Journal.finish_retire(c.directory, c.binding)
      assert {:ok, %{}} = Journal.expectations(c.directory, c.binding)
      assert {:error, _} = Journal.prepare(c.directory, c.binding)
      assert {:error, _} = Journal.bind(c.directory, c.binding, nonce, "500")
    end)
  end

  test "cancelled uncertain create may bind its old nonce only for cleanup", c do
    locked(c.directory, fn ->
      {:ok, state} = Journal.prepare(c.directory, c.binding)
      nonce = state["snapshots"]["lilly-b"]["nonce"]
      assert {:ok, _} = Journal.begin_retire(c.directory, c.binding)
      assert {:error, _} = Journal.expectations(c.directory, c.binding)
      assert {:error, _} = Journal.bind(c.directory, c.binding, "foreign", "500")
      assert {:ok, cleanup} = Journal.bind(c.directory, c.binding, nonce, "500")
      assert cleanup["phase"] == "retiring"
      assert cleanup["snapshots"]["lilly-b"]["state"] == "deleting"
      assert {:error, _} = Journal.prepare(c.directory, c.binding)
      assert {:ok, _} = Journal.deleted(c.directory, c.binding, "500")
      assert {:ok, _} = Journal.finish_retire(c.directory, c.binding)
    end)
  end

  test "retirement before generation and an unmaterialized create leave permanent fences", c do
    locked(c.directory, fn ->
      assert {:ok, _} = Journal.begin_retire(c.directory, c.binding)
      assert {:ok, _} = Journal.finish_retire(c.directory, c.binding)
      assert {:error, _} = Journal.prepare(c.directory, c.binding)
    end)

    other = Path.join(c.directory, "other")

    locked(other, fn ->
      assert {:ok, _} = Journal.prepare(other, c.binding)
      assert {:ok, _} = Journal.begin_retire(other, c.binding)
      assert {:ok, _} = Journal.deleted(other, c.binding, nil)
      assert {:ok, _} = Journal.finish_retire(other, c.binding)
      assert {:error, _} = Journal.prepare(other, c.binding)
    end)
  end

  test "all identity fields are immutable and malformed input makes no journal", c do
    assert {:ok, nil} = Journal.read(c.directory, c.binding)
    assert {:error, _} = Journal.expectations(c.directory, c.binding)
    assert {:error, _} = Journal.prepare(c.directory, c.binding)
    assert File.ls!(c.directory) == []

    locked(c.directory, fn ->
      assert {:error, _} = Journal.prepare(c.directory, %{c.binding | execution_epoch: 0})
      assert {:ok, nil} = Journal.read(c.directory, c.binding)
      assert {:ok, state} = Journal.prepare(c.directory, c.binding)

      for key <- Map.keys(c.binding) do
        other =
          case key do
            :execution_epoch -> 8
            key when key in [:zpool_guid, :parent_dataset_guid, :dataset_guid] -> "999"
            _ -> Lilly.UUID.generate()
          end

        binding = Map.put(c.binding, key, other)
        assert {:error, _} = Journal.read(c.directory, binding)
        assert {:error, _} = Journal.prepare(c.directory, binding)
        assert {:error, _} = Journal.begin_retire(c.directory, binding)
        assert {:ok, ^state} = Journal.read(c.directory, c.binding)
      end
    end)
  end

  test "unknown files, unsafe journals, removed slots and malformed state cannot be adopted", c do
    locked(c.directory, fn ->
      path = Path.join(c.directory, "snapshots.json")
      File.write!(Path.join(c.directory, "foreign"), "retain")
      assert {:error, _} = Journal.prepare(c.directory, c.binding)
      File.rm!(Path.join(c.directory, "foreign"))
      {:ok, record} = Journal.prepare(c.directory, c.binding)
      slot = record["snapshots"]["lilly-b"]

      ready_baseline = %{
        "state" => "ready",
        "nonce" => String.duplicate("a", 32),
        "guid" => "400"
      }

      for invalid <- [
            Map.put(record, "extra", true),
            Map.put(record, "snapshots", %{}),
            %{record | "phase" => "retired"},
            put_in(record, ["snapshots", "lilly-b", "guid"], "400"),
            put_in(record, ["snapshots", "lilly-b", "nonce"], "not-canonical"),
            put_in(record, ["snapshots", "foreign"], slot),
            # ADR-0155 removed the running-source baseline slot entirely.
            put_in(record, ["snapshots", "lilly-a"], ready_baseline),
            Map.put(record, "snapshots", %{"lilly-a" => ready_baseline})
          ] do
        bytes = JSON.encode!(invalid)
        :ok = PrivateFiles.write(c.directory, "snapshots.json", bytes)
        assert {:error, _} = Journal.read(c.directory, c.binding)
        assert {:error, _} = Journal.prepare(c.directory, c.binding)
        assert File.read!(path) == bytes
      end

      File.rm!(path)
      File.ln_s!("owner.lock", path)
      assert {:error, _} = Journal.begin_retire(c.directory, c.binding)
      File.rm!(path)
      File.write!(path, JSON.encode!(record))
      File.chmod!(path, 0o644)
      assert {:error, _} = Journal.read(c.directory, c.binding)
      File.chmod!(path, 0o600)
      File.ln!(path, Path.join(c.directory, "alias"))
      assert {:error, _} = Journal.read(c.directory, c.binding)
    end)
  end

  test "an unpublished private temporary does not become native creation authority", c do
    locked(c.directory, fn ->
      path = Path.join(c.directory, ".pending-abcdefghijklmnop")
      File.write!(path, "interrupted publication")
      File.chmod!(path, 0o600)
      assert {:ok, state} = Journal.prepare(c.directory, c.binding)
      assert state["snapshots"]["lilly-b"]["state"] == "creating"
      assert is_nil(state["snapshots"]["lilly-b"]["guid"])
      assert File.read!(path) == "interrupted publication"
    end)
  end

  property "arbitrary journal bytes never crash or rebind identity", c do
    check all(bytes <- binary(max_length: 1024), max_runs: 30) do
      :ok = PrivateFiles.write(c.directory, "snapshots.json", bytes)

      case Journal.read(c.directory, c.binding) do
        {:error, :snapshot_state_unconfirmed} ->
          :ok

        {:ok, record} ->
          assert record["binding"] ==
                   Map.new(c.binding, fn {key, value} -> {Atom.to_string(key), value} end)
      end
    end
  end
end
