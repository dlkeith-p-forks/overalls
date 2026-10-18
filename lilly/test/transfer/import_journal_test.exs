defmodule Lilly.Transfer.ImportJournalTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.Transfer.ImportJournal, as: Journal
  @moduletag :tmp_dir
  defp uuid(n), do: "00000000-0000-0000-0000-" <> String.pad_leading("#{n}", 12, "0")

  defp descriptor do
    %{
      relocation_id: uuid(1),
      vm_id: uuid(2),
      source: %{placement_id: uuid(3), host_id: uuid(4), pool_id: uuid(5)},
      destination: %{placement_id: uuid(6), host_id: uuid(7), pool_id: uuid(8)},
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
      stream: %{source_dataset_guid: "100", to_guid: "200"}
    }
  end

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)

    %{
      directory: directory,
      descriptor: descriptor(),
      identity: %{backend: :zfs, zpool_guid: "500", dataset_guid: "600", dataset: "target/lilly"}
    }
  end

  defp other_stream(d), do: %{d | stream: %{d.stream | to_guid: "300"}}

  defp locked(c, function) do
    {:ok, port} = Lock.acquire(c.directory)

    try do
      function.()
    after
      Lock.release(port)
    end
  end

  test "missing state and missing lock cannot be mistaken for received data", c do
    locked(c, fn ->
      task = Task.async(fn -> Journal.prepare(c.directory, c.descriptor, c.identity) end)
      assert {:error, _} = Task.await(task)

      assert {:error, _} =
               Journal.bind(
                 c.directory,
                 c.descriptor,
                 c.identity,
                 String.duplicate("a", 32),
                 "900"
               )

      assert {:error, _} = Journal.received(c.directory, c.descriptor, c.identity, "900", "200")
      assert {:ok, nil} = Journal.read(c.directory, c.descriptor, c.identity)

      for descriptor <- [nil, %{}, %{"peer" => "key"}, %{c.descriptor | source: nil}] do
        assert {:error, _} = Journal.prepare(c.directory, descriptor, c.identity)
      end

      refute File.exists?(Path.join(c.directory, "import.json"))
    end)
  end

  test "local inventory preserves storage binding and never mutates the journal", c do
    Hegel.check(
      fn ->
        replacement = draw("replacement", integer(1000..100_000))

        locked(c, fn ->
          {:ok, expected} = Journal.prepare(c.directory, c.descriptor, c.identity)
          path = Path.join(c.directory, "import.json")
          original = File.read!(path)

          assert {:ok, %{descriptor: descriptor, journal: ^expected}} =
                   Journal.local(c.directory, c.identity)

          assert descriptor == c.descriptor
          changed = %{c.identity | dataset_guid: Integer.to_string(replacement)}
          assert {:error, :import_state_unconfirmed} = Journal.local(c.directory, changed)
          assert File.read!(path) == original
        end)
      end,
      []
    )
  end

  test "local inventory rejects missing locks and malformed or foreign journals", c do
    assert {:error, :import_state_unconfirmed} = Journal.local(c.directory, c.identity)

    locked(c, fn ->
      assert {:error, :import_state_unconfirmed} = Journal.local(c.directory, c.identity)
      {:ok, record} = Journal.prepare(c.directory, c.descriptor, c.identity)
      path = Path.join(c.directory, "import.json")
      original = File.read!(path)

      for changed <- [
            Map.put(record, "extra", true),
            %{record | "nonce" => ""},
            %{record | "phase" => "unknown"},
            %{record | "stream" => %{}}
          ] do
        File.write!(path, JSON.encode!(changed))
        assert {:error, :import_state_unconfirmed} = Journal.local(c.directory, c.identity)
      end

      File.write!(path, original)
      task = Task.async(fn -> Journal.local(c.directory, c.identity) end)
      assert {:error, :import_state_unconfirmed} = Task.await(task)
    end)
  end

  test "intent retries, partial receive and one exact full stream", c do
    locked(c, fn ->
      assert {:ok, nil} = Journal.read(c.directory, c.descriptor, c.identity)
      assert {:ok, first} = Journal.prepare(c.directory, c.descriptor, c.identity)
      assert map_size(first) == 7
      assert first["stream"] == %{"source_dataset_guid" => "100", "to_guid" => "200"}
      assert {:ok, ^first} = Journal.prepare(c.directory, c.descriptor, c.identity)
      assert {:ok, ^first} = Journal.read(c.directory, c.descriptor, c.identity)
      assert {:error, _} = Journal.received(c.directory, c.descriptor, c.identity, "900", "200")
      assert {:error, _} = Journal.bind(c.directory, c.descriptor, c.identity, "wrong", "900")

      assert {:ok, bound} =
               Journal.bind(c.directory, c.descriptor, c.identity, first["nonce"], "900")

      assert {:ok, ^bound} =
               Journal.bind(c.directory, c.descriptor, c.identity, first["nonce"], "900")

      assert {:error, _} =
               Journal.bind(c.directory, c.descriptor, c.identity, first["nonce"], "901")

      assert {:error, _} = Journal.prepare(c.directory, other_stream(c.descriptor), c.identity)
      assert {:error, _} = Journal.received(c.directory, c.descriptor, c.identity, "900", "201")

      assert {:ok, final} =
               Journal.received(c.directory, c.descriptor, c.identity, "900", "200")

      assert final["dataset_guid"] != c.descriptor.stream.source_dataset_guid
      assert final["nonce"] == first["nonce"]
      assert {:ok, ^final} = Journal.received(c.directory, c.descriptor, c.identity, "900", "200")
      assert {:ok, ^final} = Journal.prepare(c.directory, c.descriptor, c.identity)
      assert final["stream_state"] == "received" and final["phase"] == "active"
      # A received import never admits a successor stream (ADR-0155 removed incrementals).
      assert {:error, _} = Journal.prepare(c.directory, other_stream(c.descriptor), c.identity)

      assert {:error, _} =
               Journal.received(c.directory, other_stream(c.descriptor), c.identity, "900", "300")
    end)
  end

  test "retirement fences uncertain receive and retains exact deletion tombstone", c do
    locked(c, fn ->
      {:ok, first} = Journal.prepare(c.directory, c.descriptor, c.identity)
      assert {:error, _} = Journal.deleted(c.directory, c.descriptor, c.identity, nil)
      assert {:ok, _} = Journal.retire(c.directory, c.descriptor, c.identity)
      assert {:error, _} = Journal.prepare(c.directory, c.descriptor, c.identity)
      assert {:ok, _} = Journal.bind(c.directory, c.descriptor, c.identity, first["nonce"], "900")
      assert {:error, _} = Journal.received(c.directory, c.descriptor, c.identity, "900", "200")
      assert {:error, _} = Journal.deleted(c.directory, c.descriptor, c.identity, nil)
      assert {:error, _} = Journal.deleted(c.directory, c.descriptor, c.identity, "901")
      assert {:ok, deleted} = Journal.deleted(c.directory, c.descriptor, c.identity, "900")
      assert {:ok, ^deleted} = Journal.deleted(c.directory, c.descriptor, c.identity, "900")
      assert {:ok, ^deleted} = Journal.retire(c.directory, c.descriptor, c.identity)
      assert {:error, _} = Journal.prepare(c.directory, c.descriptor, c.identity)

      assert {:error, _} =
               Journal.bind(c.directory, c.descriptor, c.identity, first["nonce"], "900")
    end)
  end

  test "cancellation before receive permanently rejects later preparation", c do
    locked(c, fn ->
      assert {:ok, pending} = Journal.retire(c.directory, c.descriptor, c.identity)
      assert pending["dataset_guid"] == nil
      assert {:ok, _} = Journal.deleted(c.directory, c.descriptor, c.identity, nil)
      assert {:error, _} = Journal.prepare(c.directory, c.descriptor, c.identity)
    end)
  end

  test "immutable identities, closed state and unsafe files fail without rebinding", c do
    locked(c, fn ->
      {:ok, original} = Journal.prepare(c.directory, c.descriptor, c.identity)

      for changed <- [
            put_in(c.descriptor, [:destination, :placement_id], uuid(90)),
            put_in(c.descriptor, [:stream, :source_dataset_guid], "999"),
            put_in(c.descriptor, [:workload, :slot], 3),
            %{c.descriptor | source_epoch: 2, destination_epoch: 3}
          ] do
        assert {:error, _} = Journal.prepare(c.directory, changed, c.identity)
      end

      assert {:error, _} =
               Journal.prepare(c.directory, c.descriptor, %{c.identity | dataset_guid: "999"})

      assert {:ok, ^original} = Journal.read(c.directory, c.descriptor, c.identity)
      path = Path.join(c.directory, "import.json")
      File.chmod!(path, 0o644)
      assert {:error, _} = Journal.read(c.directory, c.descriptor, c.identity)
      File.chmod!(path, 0o600)

      for invalid <- [
            Map.put(original, "execute", true),
            %{original | "stream_state" => "received"},
            Map.put(original, "unreviewed", nil)
          ] do
        :ok = PrivateFiles.write(c.directory, "import.json", JSON.encode!(invalid))
        assert {:error, _} = Journal.read(c.directory, c.descriptor, c.identity)
      end
    end)
  end

  test "arbitrary persisted bytes never crash or change immutable scope", c do
    locked(c, fn ->
      Hegel.check(
        fn ->
          bytes = draw("bytes", binary(max_length: 4096))
          :ok = PrivateFiles.write(c.directory, "import.json", bytes)

          assert {:error, :import_state_unconfirmed} =
                   Journal.for_intent(c.directory, Map.delete(c.descriptor, :stream), c.identity)

          case Journal.read(c.directory, c.descriptor, c.identity) do
            {:error, :import_state_unconfirmed} ->
              :ok

            {:ok, record} ->
              assert record["binding"]["local_storage"] ==
                       OverallsProtocol.Storage.encode(c.identity)

              assert record["binding"]["relocation_id"] == c.descriptor.relocation_id
          end
        end,
        []
      )
    end)
  end

  test "intent lookup recovers current lineage through receive and retirement without mutation",
       c do
    intent = Map.delete(c.descriptor, :stream)
    assert {:error, _} = Journal.for_intent(c.directory, intent, c.identity)

    locked(c, fn ->
      assert {:ok, nil} = Journal.for_intent(c.directory, intent, c.identity)
      refute File.exists?(Path.join(c.directory, "import.json"))
      {:ok, first} = Journal.prepare(c.directory, c.descriptor, c.identity)

      assert {:ok, %{descriptor: descriptor, journal: ^first}} =
               Journal.for_intent(c.directory, intent, c.identity)

      assert descriptor == c.descriptor
      {:ok, _} = Journal.bind(c.directory, descriptor, c.identity, first["nonce"], "900")
      {:ok, received} = Journal.received(c.directory, descriptor, c.identity, "900", "200")
      next = descriptor

      assert {:ok, %{descriptor: ^next, journal: ^received}} =
               Journal.for_intent(c.directory, intent, c.identity)

      {:ok, retiring} = Journal.retire(c.directory, next, c.identity)

      assert {:ok, %{descriptor: ^next, journal: ^retiring}} =
               Journal.for_intent(c.directory, intent, c.identity)

      {:ok, retired} = Journal.deleted(c.directory, next, c.identity, "900")
      bytes = File.read!(Path.join(c.directory, "import.json"))

      for _ <- 1..2 do
        assert {:ok, %{descriptor: ^next, journal: ^retired}} =
                 Journal.for_intent(c.directory, intent, c.identity)
      end

      assert File.read!(Path.join(c.directory, "import.json")) == bytes
    end)
  end

  test "intent lookup rejects foreign authority, corrupt lineage and unsafe history", c do
    locked(c, fn ->
      intent = Map.delete(c.descriptor, :stream)
      {:ok, original} = Journal.prepare(c.directory, c.descriptor, c.identity)

      for changed <- [
            nil,
            %{},
            c.descriptor,
            Map.put(intent, :unknown, true),
            %{intent | relocation_id: uuid(91)},
            %{intent | vm_id: uuid(92)},
            put_in(intent, [:source, :host_id], uuid(93)),
            put_in(intent, [:destination, :placement_id], uuid(94)),
            put_in(intent, [:workload, :slot], 3),
            %{intent | source_epoch: 2, destination_epoch: 3}
          ] do
        assert {:error, _} = Journal.for_intent(c.directory, changed, c.identity)
      end

      for identity <- [
            nil,
            %{},
            Map.put(c.identity, :extra, true),
            %{c.identity | dataset_guid: "999"}
          ] do
        assert {:error, _} = Journal.for_intent(c.directory, intent, identity)
      end

      assert {:ok, %{journal: ^original}} = Journal.for_intent(c.directory, intent, c.identity)

      for invalid <- [
            Map.put(original, "execute", true),
            put_in(original, ["binding", "source_dataset_guid"], "999"),
            put_in(original, ["binding", "local_storage", "dataset_guid"], "999"),
            %{original | "binding" => nil},
            %{original | "stream" => nil},
            %{original | "stream_state" => "received"},
            Map.put(original, "unreviewed", nil)
          ] do
        :ok = PrivateFiles.write(c.directory, "import.json", JSON.encode!(invalid))
        assert {:error, _} = Journal.for_intent(c.directory, intent, c.identity)
      end

      :ok = PrivateFiles.write(c.directory, "import.json", JSON.encode!(original))
      path = Path.join(c.directory, "import.json")
      File.chmod!(path, 0o644)
      assert {:error, _} = Journal.for_intent(c.directory, intent, c.identity)
      File.chmod!(path, 0o600)
      File.rename!(path, Path.join(c.directory, "saved.json"))
      File.ln_s!("saved.json", path)
      assert {:error, _} = Journal.for_intent(c.directory, intent, c.identity)
    end)
  end
end
