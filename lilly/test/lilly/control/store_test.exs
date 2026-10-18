defmodule Lilly.Control.StoreTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Control.Store
  alias Lilly.Host.{Lock, PrivateFiles}
  @id "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    {:ok, store} = Store.open(directory, @id)
    %{store: store, directory: directory}
  end

  test "owning-user metadata survives durable command recovery", %{
    store: store,
    directory: directory
  } do
    owned = %{command(1, @id) | owner_id: @other}
    assert {:ok, :stored} = Store.accept(store, owned)
    assert {:ok, reopened} = Store.open(directory, @id)
    assert {:ok, ^owned} = Store.read(reopened, @id)
    assert {:error, _} = Store.accept(reopened, %{owned | owner_id: @id})
  end

  test "the stored owner is immutable across newer, equal and stale intent", %{
    store: store
  } do
    owned = %{command(2, @id) | owner_id: @other}
    assert {:ok, :stored} = Store.accept(store, owned)

    for changed <- [
          %{command(3, Lilly.UUID.generate()) | owner_id: @id},
          %{command(2, @id) | owner_id: @id},
          %{command(1, Lilly.UUID.generate()) | owner_id: @id}
        ] do
      assert {:error, :vm_identity_conflict} = Store.accept(store, changed)
    end

    assert {:error, :invalid_command} =
             Store.accept(store, Map.delete(command(3, @id), :owner_id))

    assert {:ok, ^owned} = Store.read(store, @id)
    newer = %{command(3, Lilly.UUID.generate()) | owner_id: @other}
    assert {:ok, :stored} = Store.accept(store, newer)
    assert {:ok, ^newer} = Store.read(store, @id)
  end

  test "only recorded stopped resize rebinds resources across store restart", %{
    store: store,
    directory: directory
  } do
    stop = %{command(1, @id) | kind: :stop}
    assert {:ok, :stored} = Store.accept(store, stop)
    target = %{command(2, @other) | kind: :start, vcpu: 2}
    assert {:error, :vm_identity_conflict} = Store.accept(store, target)

    resize =
      Map.merge(target, %{
        kind: :resize,
        resize_from: OverallsProtocol.Resize.sizes(stop),
        resize_id: @other
      })

    assert {:ok, :stored} = Store.accept(store, resize)
    assert {:ok, reopened} = Store.open(directory, @id)
    assert {:ok, :duplicate} = Store.accept(reopened, resize)

    assert {:error, :vm_identity_conflict} =
             Store.accept(reopened, %{resize | generation: 3, vcpu: 3})

    start =
      Map.put(
        %{target | id: "33333333-3333-4333-8333-333333333333", generation: 3},
        :resize_id,
        @other
      )

    assert {:ok, :stored} = Store.accept(reopened, start)

    assert {:error, :vm_identity_conflict} =
             Store.accept(reopened, %{start | generation: 4, disk_bytes: start.disk_bytes * 2})
  end

  test "clone readiness metadata permits restoration and later ordinary lifecycle", %{
    store: store,
    directory: directory
  } do
    stop = %{command(1, @id) | kind: :stop}
    start = Map.put(%{command(2, @other) | kind: :start}, :clone_id, @other)
    assert {:ok, :stored} = Store.accept(store, stop)
    assert {:ok, :stored} = Store.accept(store, start)
    assert {:ok, reopened} = Store.open(directory, @id)
    assert {:ok, :duplicate} = Store.accept(reopened, start)
    assert {:ok, :stale} = Store.accept(reopened, stop)
    assert {:error, :generation_conflict} = Store.accept(reopened, %{start | clone_id: @id})
    assert {:error, :operation_conflict} = Store.accept(reopened, %{start | generation: 3})

    ordinary = %{command(3, "33333333-3333-4333-8333-333333333333") | kind: :stop}
    assert {:ok, :stored} = Store.accept(reopened, ordinary)
    next = %{start | id: @id, generation: 4, clone_id: @id}
    assert {:ok, :stored} = Store.accept(reopened, next)

    for change <- [%{slot: 3}, %{vm_id: @other}, %{vcpu: 2}, %{disk_bytes: next.disk_bytes * 2}] do
      altered = Map.merge(next, change) |> Map.merge(%{id: @other, generation: 5})
      assert {:error, :vm_identity_conflict} = Store.accept(reopened, altered)
    end
  end

  # Regression (ADR-0128): the provision command pins a workspace source while
  # later stop/delete commands do not. The reference is operation metadata, so a
  # generated lifecycle MUST never fence the store as an identity conflict, while
  # genuine placement identity changes still conflict.
  @tag :hegel
  test "workspace source metadata never turns ordinary lifecycle into a conflict", %{
    directory: directory
  } do
    source = %{
      provider: :github,
      namespace: ["tastejs"],
      repository: "todomvc",
      revision: %{kind: :default}
    }

    Hegel.check(
      fn ->
        kinds =
          draw(
            "kinds",
            list_of(member_of([:stop, :start, :delete]), min_length: 1, max_length: 8)
          )

        carries = draw("carries", list_of(boolean(), length: length(kinds)))
        root = Path.join(directory, Integer.to_string(System.unique_integer([:positive])))
        File.mkdir_p!(root)
        File.chmod!(root, 0o700)
        {:ok, store} = Store.open(root, @id)

        provision =
          Map.put(%{command(1, Lilly.UUID.generate()) | profile: :oss}, :workspace_source, source)

        assert {:ok, :stored} = Store.accept(store, provision)

        last =
          kinds
          |> Enum.zip(carries)
          |> Enum.with_index(2)
          |> Enum.reduce(provision, fn {{kind, carry}, generation}, _previous ->
            next = %{command(generation, Lilly.UUID.generate()) | kind: kind, profile: :oss}

            next =
              if carry and kind == :start,
                do: Map.put(next, :workspace_source, source),
                else: next

            assert {:ok, :stored} = Store.accept(store, next)
            next
          end)

        altered = Map.merge(last, %{id: Lilly.UUID.generate(), generation: 100, slot: 3})
        assert {:error, :vm_identity_conflict} = Store.accept(store, altered)
      end,
      test_cases: 100
    )
  end

  test "unrecognized guest SSH key field cannot enter the durable store", %{
    store: store,
    directory: _directory
  } do
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 1::256>>)
    provision = Map.put(command(1, @id), :ssh_public_key, key)
    assert {:error, :invalid_command} = Store.accept(store, provision)
  end

  test "a higher generation cannot override a newer execution epoch", %{
    store: store,
    directory: directory
  } do
    old = command(100, @id)
    fresh = %{command(101, @other) | execution_epoch: 2}
    assert {:ok, :stored} = Store.accept(store, old)
    assert {:ok, :stored} = Store.accept(store, fresh)
    assert {:ok, :stale} = Store.accept(store, %{old | generation: 1000})
    assert {:ok, reopened} = Store.open(directory, @id)
    assert {:ok, ^fresh} = Store.read(reopened, @id)
    assert {:error, :invalid_state_store} = Store.open(directory, @id, 2)

    assert {:error, :vm_identity_conflict} =
             Store.accept(reopened, %{fresh | vm_id: @other, execution_epoch: 3})
  end

  test "intent is durable, duplicates are idempotent and generations never move backwards", %{
    store: store,
    directory: directory
  } do
    first = command(1, @id)
    second = command(2, @other)
    assert {:ok, :stored} = Store.accept(store, first)
    assert {:ok, :duplicate} = Store.accept(store, first)
    assert {:ok, :stored} = Store.accept(store, second)
    assert {:ok, :stale} = Store.accept(store, first)
    assert {:ok, reopened} = Store.open(directory, @id)
    assert {:ok, ^second} = Store.read(reopened, @id)
    assert {:ok, [^second]} = Store.all(reopened)
    assert {:error, :generation_conflict} = Store.accept(store, %{second | kind: :delete})
    assert {:error, :operation_conflict} = Store.accept(store, %{second | generation: 3})
    assert {:error, :invalid_state_store} = Store.open(directory, @other)
    assert {:ok, stat} = File.stat(Path.join(store.path, @id <> ".json"))
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "retained copies of a logical VM have independent durable commands", %{
    store: store,
    directory: directory
  } do
    source = %{command(10, @id) | kind: :delete}
    destination = %{command(1, @other) | placement_id: @other, execution_epoch: 2}
    assert {:ok, :stored} = Store.accept(store, source)
    assert {:ok, :stored} = Store.accept(store, destination)
    assert {:ok, reopened} = Store.open(directory, @id)
    assert {:ok, ^source} = Store.read(reopened, source.placement_id)
    assert {:ok, ^destination} = Store.read(reopened, destination.placement_id)
    assert {:ok, copies} = Store.all(reopened)
    assert MapSet.new(copies) == MapSet.new([source, destination])
  end

  @tag :hegel
  test "out-of-order delivery preserves the highest generation", %{store: store} do
    Hegel.check(
      fn ->
        generations = draw("generations", uniq_list_of(integer(1..10000), min: 1, max: 8))
        File.rm(Path.join(store.path, @id <> ".json"))

        for generation <- generations do
          operation =
            "00000000-0000-4000-8000-" <>
              String.pad_leading(String.downcase(Integer.to_string(generation, 16)), 12, "0")

          assert {:ok, _} = Store.accept(store, command(generation, operation))
        end

        assert {:ok, current} = Store.read(store, @id)
        assert current.generation == Enum.max(generations)
      end,
      test_cases: 100
    )
  end

  test "another process cannot own the directory until the port owner exits", %{
    directory: directory
  } do
    {:ok, lock} = Lock.acquire(directory)

    assert {:error, :host_already_owned} =
             Task.async(fn -> Lock.acquire(directory) end) |> Task.await()

    assert :ok = Lock.release(lock)
    # Closing the port gives cat EOF. Each retry performs a real OS lock attempt
    # while the previous owner finishes its short, asynchronous exit.
    assert {:ok, new_lock} = eventually_lock(directory, 20)
    assert :ok = Lock.release(new_lock)
  end

  test "symlink command files, corrupt JSON and permissive secret files are rejected", %{
    store: store,
    directory: directory
  } do
    path = Path.join(store.path, @id <> ".json")
    File.write!(path, "broken")
    assert {:error, :invalid_stored_command} = Store.read(store, @id)
    File.rm!(path)
    File.ln_s!(Path.join(directory, "identity.json"), path)
    assert {:error, :invalid_stored_command} = Store.read(store, @id)
    secret = Path.join(directory, "configuration.json")
    File.write!(secret, "{}")
    File.chmod!(secret, 0o644)
    assert {:error, :unsafe_credential_file} = PrivateFiles.read_secret(secret)
    assert {:error, :unsafe_state_directory} = PrivateFiles.write(directory, "../escape", "data")
  end

  test "v3 binds executable image/address intent and cannot reopen as v1", %{directory: directory} do
    path = Path.join(directory, "execution")
    {:ok, store} = Store.open(path, @id, 3)

    first =
      Map.merge(command(1, @id), %{image_id: "sha256:" <> String.duplicate("a", 64), slot: 2})

    assert {:ok, :stored} = Store.accept(store, first)

    assert {:error, :invalid_command} =
             Store.accept(store, Map.drop(command(2, @other), [:image_id, :slot]))

    assert {:error, :invalid_state_store} = Store.open(path, @id, 1)
    assert {:ok, reopened} = Store.open(path, @id, 3)
    assert {:ok, ^first} = Store.read(reopened, @id)

    for change <- [%{slot: 3}, %{image_id: "sha256:" <> String.duplicate("b", 64)}, %{vcpu: 2}] do
      next = Map.merge(first, change) |> Map.merge(%{generation: 2, id: @other})
      assert {:error, :vm_identity_conflict} = Store.accept(reopened, next)
    end
  end

  test "retirement requires the current delete and a held ownership lock", %{directory: directory} do
    path = Path.join(directory, "retire")
    {:ok, store} = Store.open(path, @id, 3)

    command =
      Map.merge(command(2, @other), %{
        kind: :delete,
        image_id: "sha256:" <> String.duplicate("a", 64),
        slot: 2
      })

    assert {:ok, :stored} = Store.accept(store, command)
    assert {:error, :command_store_failed} = Store.retire(store, command)
    {:ok, lock} = Lock.acquire(path)

    try do
      assert {:error, :command_store_failed} = Store.retire(store, %{command | generation: 1})
      assert {:ok, ^command} = Store.read(store, @id)
      assert :ok = Store.retire(store, command)
      assert {:ok, []} = Store.all(store)
      assert {:ok, reopened} = Store.open(path, @id, 3)
      assert {:ok, nil} = Store.read(reopened, @id)
    after
      Lock.release(lock)
    end
  end

  defp command(generation, id),
    do: %{
      id: id,
      vm_id: @id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      generation: generation,
      kind: :provision,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2
    }

  defp eventually_lock(directory, attempts) do
    case Lock.acquire(directory) do
      {:error, :host_already_owned} when attempts > 0 -> eventually_lock(directory, attempts - 1)
      result -> result
    end
  end
end
