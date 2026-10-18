defmodule Lilly.Transfer.CloneCopyJournalTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.DiskTransfer
  alias Lilly.Host.Lock
  alias Lilly.Transfer.CloneCopyJournal, as: Journal
  @moduletag :tmp_dir

  defp id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  defp descriptor do
    {:ok, descriptor} =
      DiskTransfer.descriptor(%{
        "version" => 3,
        "purpose" => "clone",
        "relocation_id" => id(1),
        "vm_id" => id(2),
        "destination_vm_id" => id(3),
        "source_slot" => 2,
        "source" => %{"host_id" => id(4), "pool_id" => id(5), "placement_id" => id(6)},
        "destination" => %{"host_id" => id(4), "pool_id" => id(5), "placement_id" => id(7)},
        "source_epoch" => 9,
        "destination_epoch" => 1,
        "workload" => %{
          "image_id" => "sha256:" <> String.duplicate("a", 64),
          "architecture" => "x86_64",
          "profile" => "customer",
          "slot" => 3,
          "vcpu" => 1,
          "memory_bytes" => 536_870_912,
          "disk_bytes" => 2_147_483_648
        },
        "stream" => %{
          "source_dataset_guid" => "100",
          "to_guid" => "200"
        }
      })

    descriptor
  end

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)

    %{
      directory: Path.join(directory, "copies"),
      lock: directory,
      descriptor: descriptor(),
      identity: %{backend: :zfs, zpool_guid: "500", dataset_guid: "600", dataset: "pool/lilly"}
    }
  end

  defp locked(c, function) do
    {:ok, port} = Lock.acquire(c.lock)

    try do
      function.()
    after
      Lock.release(port)
    end
  end

  @nonce String.duplicate("a", 32)
  @source [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
  @files ~w(rootfs.ext4 kernel initrd boot-bundle.json)

  test "no mutation happens without the owning lock", c do
    assert {:error, _} = Journal.prepare(c.directory, c.descriptor, c.identity)
    refute File.exists?(c.directory)
  end

  test "intent, bound claim, every file, copy and adoption progress in order", c do
    locked(c, fn ->
      assert {:ok, %{"phase" => "copying", "nonce" => nil, "snapshot_guid" => "200"}} =
               Journal.prepare(c.directory, c.descriptor, c.identity)

      # Files cannot be recorded before the destination claim is bound.
      assert {:error, _} =
               Journal.file_copied(
                 c.directory,
                 c.descriptor,
                 c.identity,
                 "rootfs.ext4",
                 1,
                 @source
               )

      assert {:ok, _} = Journal.bind(c.directory, c.descriptor, c.identity, @nonce, "300")

      for name <- @files do
        assert {:ok, _} =
                 Journal.file_copied(c.directory, c.descriptor, c.identity, name, 4096, @source)
      end

      assert {:ok, %{"phase" => "copied"}} =
               Journal.copied(c.directory, c.descriptor, c.identity, "300", @files)

      # Retries are idempotent and a copied journal cannot lose files.
      assert {:ok, %{"phase" => "copied"}} =
               Journal.copied(c.directory, c.descriptor, c.identity, "300", @files)

      assert {:ok, %{"phase" => "adopted"}} =
               Journal.adopted(c.directory, c.descriptor, c.identity, "300")

      # A cancelled clone's discard retires even a locally adopted copy, and the
      # retirement fences any further adoption or completion.
      assert {:ok, %{"phase" => "retiring"}} =
               Journal.retire(c.directory, c.descriptor, c.identity)

      assert {:error, _} = Journal.adopted(c.directory, c.descriptor, c.identity, "300")
      assert {:error, _} = Journal.copied(c.directory, c.descriptor, c.identity, "300", @files)
      assert {:error, _} = Journal.deleted(c.directory, c.descriptor, c.identity, "301")

      assert {:ok, %{"phase" => "retired"}} =
               Journal.deleted(c.directory, c.descriptor, c.identity, "300")
    end)
  end

  @tag :hegel
  test "bindings, file records and completion refuse every conflicting history", c do
    Hegel.check(
      fn ->
        other_nonce = draw("other_nonce", member_of([String.duplicate("b", 32), "short", @nonce]))
        other_guid = draw("other_guid", member_of(["300", "301"]))
        other_size = draw("other_size", member_of([4096, 4097]))
        missing = draw("missing", member_of(@files))
        directory = Path.join(c.directory, Integer.to_string(System.unique_integer([:positive])))
        c = %{c | directory: directory}

        locked(c, fn ->
          {:ok, _} = Journal.prepare(directory, c.descriptor, c.identity)
          {:ok, _} = Journal.bind(directory, c.descriptor, c.identity, @nonce, "300")

          rebind = Journal.bind(directory, c.descriptor, c.identity, other_nonce, other_guid)

          assert match?({:ok, _}, rebind) == (other_nonce == @nonce and other_guid == "300")

          {:ok, _} =
            Journal.file_copied(directory, c.descriptor, c.identity, "kernel", 4096, @source)

          rerecord =
            Journal.file_copied(
              directory,
              c.descriptor,
              c.identity,
              "kernel",
              other_size,
              @source
            )

          assert match?({:ok, _}, rerecord) == (other_size == 4096)

          assert {:error, _} =
                   Journal.file_copied(
                     directory,
                     c.descriptor,
                     c.identity,
                     "../escape",
                     1,
                     @source
                   )

          for name <- @files -- [missing], name != "kernel" do
            {:ok, _} = Journal.file_copied(directory, c.descriptor, c.identity, name, 1, @source)
          end

          complete = Journal.copied(directory, c.descriptor, c.identity, "300", @files)
          assert match?({:ok, _}, complete) == (missing == "kernel")
          assert {:error, _} = Journal.copied(directory, c.descriptor, c.identity, "301", @files)
        end)
      end,
      test_cases: 100
    )
  end

  test "retirement is permanent and requires the exact bound GUID", c do
    locked(c, fn ->
      {:ok, _} = Journal.prepare(c.directory, c.descriptor, c.identity)
      {:ok, _} = Journal.bind(c.directory, c.descriptor, c.identity, @nonce, "300")

      assert {:ok, %{"phase" => "retiring"}} =
               Journal.retire(c.directory, c.descriptor, c.identity)

      assert {:error, _} =
               Journal.file_copied(c.directory, c.descriptor, c.identity, "kernel", 1, @source)

      assert {:error, _} = Journal.deleted(c.directory, c.descriptor, c.identity, "301")

      assert {:ok, %{"phase" => "retired"}} =
               Journal.deleted(c.directory, c.descriptor, c.identity, "300")

      assert {:error, _} = Journal.prepare(c.directory, c.descriptor, c.identity)

      assert {:ok, %{"phase" => "retired"}} =
               Journal.retire(c.directory, c.descriptor, c.identity)
    end)
  end
end
