defmodule ZFSGuestCloneMatrixFixture do
  @moduledoc false
  alias Lilly.Control.{Client, Store}
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.Clone.Effects

  # @cc [owner:ghuntley,label:verification;storage] clone-native-matrix-cycle
  # Each invocation MUST run the production clone effects against owned ZFS
  # storage for the exact admitted workload row, including one grown by a
  # completed resize. The adopted destination MUST physically carry the
  # source's exact disk size; replayed effects MUST return identical receipts;
  # revoked and pruned identities MUST fail closed. No stage may inject
  # outcomes or bypass intent, descriptor or permit validation.
  @spec run(
          Lilly.VM.Config.t(),
          Lilly.Host.Pool.t(),
          Lilly.Host.Image.t(),
          Lilly.VM.Spec.t(),
          pos_integer(),
          pos_integer()
        ) :: :ok
  def run(execution, pool, image, source, generation, target) do
    root = "/var/lib/lilly/clone-matrix-transfers"
    state = "/var/lib/lilly/clone-matrix-control"
    :ok = PrivateFiles.directory(root)
    {:ok, lock} = Lock.acquire(state)

    try do
      {:ok, store} = Store.open(state, pool.host_id)

      runtime = %Lilly.Control.Config{
        client: %Client{
          host_id: pool.host_id,
          base_url: "https://fixture.invalid",
          token: "unused"
        },
        state_dir: state,
        cgroup_path: "/sys/fs/cgroup/lilly.slice",
        pools: [pool],
        images: [image],
        execution: execution,
        transfer_state_dir: root,
        transfer_bytes_per_second: 67_108_864
      }

      # Probe-addressable placements: the adopted copy MUST stay bootable through
      # the ordinary zfs-guest actions that rebuild specs from the same number.
      clone = "cccccccc-cccc-4ccc-8ccc-" <> String.pad_leading(to_string(target), 12, "0")
      destination = "dddddddd-dddd-4ddd-8ddd-" <> String.pad_leading(to_string(target), 12, "0")

      intent = %{
        "version" => 3,
        "purpose" => "clone",
        "relocation_id" => clone,
        "vm_id" => source.id,
        "destination_vm_id" => destination,
        "source_slot" => source.network.slot,
        "source" => %{
          "host_id" => pool.host_id,
          "pool_id" => pool.id,
          "placement_id" => source.id
        },
        "destination" => %{
          "host_id" => pool.host_id,
          "pool_id" => pool.id,
          "placement_id" => destination
        },
        "source_epoch" => 1,
        "destination_epoch" => 1,
        "workload" => %{
          "architecture" => "x86_64",
          "image_id" => image.id,
          "profile" => Atom.to_string(source.network.profile),
          "slot" => target + 2,
          "vcpu" => source.vcpu,
          "memory_bytes" => source.memory_bytes,
          "disk_bytes" => source.disk_bytes
        }
      }

      current = %{
        owner_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        id: clone,
        vm_id: source.id,
        placement_id: source.id,
        execution_epoch: 1,
        host_id: pool.host_id,
        pool_id: pool.id,
        generation: generation,
        kind: :stop,
        architecture: :x86_64,
        image_id: image.id,
        profile: source.network.profile,
        slot: source.network.slot,
        vcpu: source.vcpu,
        memory_bytes: source.memory_bytes,
        disk_bytes: source.disk_bytes
      }

      {:ok, _} = Store.accept(store, current)

      command = %{
        "id" => clone,
        "clone_id" => clone,
        "host_id" => pool.host_id,
        "kind" => "prepare",
        "endpoint" => "destination",
        "intent" => intent,
        "descriptor" => nil,
        "public_key" => nil,
        "source_endpoint" => nil,
        "source_generation" => generation,
        "revision" => System.system_time(:second),
        "expires_at" => System.system_time(:second) + 180
      }

      prepare = effect(runtime, store, command)
      command = Map.put(command, "public_key", prepare["public_key"])
      captured = effect(runtime, store, %{command | "kind" => "capture", "endpoint" => "source"})
      command = Map.put(command, "descriptor", captured["descriptor"])

      ^captured =
        effect(runtime, store, %{
          command
          | "kind" => "capture",
            "endpoint" => "source",
            "revision" => command["revision"] + 1
        })

      copied = effect(runtime, store, %{command | "kind" => "copy"})
      true = is_binary(copied["dataset_guid"])
      ^copied = effect(runtime, store, %{command | "kind" => "copy"})
      :ok = copy_mode(pool, destination, "copied")
      %{} = effect(runtime, store, %{command | "kind" => "adopt"})
      %{} = effect(runtime, store, %{command | "kind" => "adopt"})
      :ok = copy_mode(pool, destination, "adopted")

      # The adopted destination physically carries the exact captured shape.
      adopted = %{source | id: destination}
      true = File.stat!(Lilly.VM.Disk.path(pool, adopted)).size == source.disk_bytes

      %{} = effect(runtime, store, %{command | "kind" => "revoke", "endpoint" => "source"})
      %{} = effect(runtime, store, %{command | "kind" => "revoke", "endpoint" => "destination"})
      %{} = effect(runtime, store, %{command | "kind" => "prune", "endpoint" => "source"})
      %{} = effect(runtime, store, %{command | "kind" => "prune", "endpoint" => "source"})

      for kind <- ["copy", "adopt"] do
        {:error, _} =
          Task.async(fn -> Effects.execute(runtime, store, %{command | "kind" => kind}) end)
          |> Task.await(180_000)
      end

      discarded_copy(runtime, store, pool, command, target)
    after
      Lock.release(lock)
    end
  end

  # A same-pool clone is always a block copy (ADR-0145): it MUST leave durable
  # copy history in the expected phase.
  defp copy_mode(pool, placement, phase) do
    path = Path.join(Lilly.Transfer.CloneCopyJournal.directory(pool.path, placement), "copy.json")
    {:ok, bytes} = File.read(path)
    {:ok, %{"phase" => ^phase}} = Lilly.Lifecycle.Journal.decode(bytes)
    :ok
  end

  # A copied but unadopted block copy discarded after cancellation MUST retire
  # its journal, destroy only its own destination and leave the source prunable.
  defp discarded_copy(runtime, store, pool, command, target) do
    cancelled = Lilly.UUID.generate()
    number = target + 50
    unused = "dddddddd-dddd-4ddd-8ddd-" <> String.pad_leading(to_string(number), 12, "0")

    intent =
      command["intent"]
      |> Map.put("relocation_id", cancelled)
      |> Map.put("destination_vm_id", unused)
      |> put_in(["destination", "placement_id"], unused)
      |> put_in(["workload", "slot"], number + 2)

    command = %{
      command
      | "id" => cancelled,
        "clone_id" => cancelled,
        "intent" => intent,
        "descriptor" => nil,
        "public_key" => nil,
        "kind" => "prepare",
        "endpoint" => "destination",
        "revision" => System.system_time(:second)
    }

    prepare = effect(runtime, store, command)
    command = Map.put(command, "public_key", prepare["public_key"])
    captured = effect(runtime, store, %{command | "kind" => "capture", "endpoint" => "source"})
    command = Map.put(command, "descriptor", captured["descriptor"])
    %{} = effect(runtime, store, %{command | "kind" => "copy"})
    :ok = copy_mode(pool, unused, "copied")
    dataset = pool.storage.dataset <> "/vm-" <> unused
    {_, 0} = System.cmd("zfs", ["list", "-H", dataset])
    %{} = effect(runtime, store, %{command | "kind" => "revoke", "endpoint" => "source"})
    %{} = effect(runtime, store, %{command | "kind" => "revoke", "endpoint" => "destination"})
    %{} = effect(runtime, store, %{command | "kind" => "discard"})
    %{} = effect(runtime, store, %{command | "kind" => "discard"})
    :ok = copy_mode(pool, unused, "retired")
    {_, status} = System.cmd("zfs", ["list", "-H", dataset], stderr_to_stdout: true)
    true = status != 0
    mount = Lilly.Transfer.CloneCopy.mount_path(%{relocation_id: cancelled})
    {_, 1} = System.cmd("findmnt", ["--mountpoint", mount])
    %{} = effect(runtime, store, %{command | "kind" => "prune", "endpoint" => "source"})
    :ok
  end

  defp effect(runtime, store, command) do
    Task.async(fn ->
      case Effects.execute(runtime, store, command) do
        {:ok, %{"result" => result}} -> result
        {:error, reason} -> raise "Clone matrix #{command["kind"]} unconfirmed: #{reason}"
      end
    end)
    |> Task.await(180_000)
  end
end
