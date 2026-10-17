defmodule ZFSGuestReadinessFixture do
  @moduledoc false
  alias Lilly.Control.{Client, Store}
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.Transfer.ReadinessProbe
  alias Lilly.VM.{Driver, Observation}

  # @cc [owner:ghuntley,label:verification] readiness-probe-real-guest-not-relocation
  # This fixture MUST probe a real confined guest through the production store
  # and readiness effect, reject mismatched activation authority, and clean up its
  # guest afterward. Its synthetic relocation descriptor MUST NOT establish disk
  # transfer, Marshall transport or a complete cross-host guest move.
  @spec run(Lilly.VM.Config.t(), Lilly.Host.Pool.t(), Lilly.Host.Image.t(), Lilly.VM.Spec.t()) ::
          :ok
  def run(config, pool, image, spec) do
    :ok = Lilly.Network.setup(config.network)
    :ok = Driver.start(config, pool, image, spec, execution_epoch: 2, generation: 1)
    running(config, pool, spec, System.monotonic_time(:millisecond) + 30_000)
    state = "/var/lib/lilly/readiness-control"
    :ok = PrivateFiles.directory(state)
    {:ok, lock} = Lock.acquire(state)

    try do
      {:ok, store} = Store.open(state, pool.host_id)

      command = %{
        owner_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        id: "88888888-8888-4888-8888-000000000103",
        vm_id: spec.id,
        placement_id: spec.id,
        execution_epoch: 2,
        host_id: pool.host_id,
        pool_id: pool.id,
        generation: 1,
        kind: :start,
        architecture: :x86_64,
        image_id: spec.image_id,
        profile: spec.network.profile,
        slot: spec.network.slot,
        vcpu: spec.vcpu,
        memory_bytes: spec.memory_bytes,
        disk_bytes: spec.disk_bytes
      }

      {:ok, _} = Store.accept(store, command)

      descriptor = %{
        relocation_id: "ffffffff-ffff-4fff-8fff-000000000103",
        vm_id: spec.id,
        source_epoch: 1,
        destination_epoch: 2,
        source: %{
          host_id: "aaaaaaaa-aaaa-4aaa-8aaa-000000000001",
          placement_id: "dddddddd-dddd-4ddd-8ddd-000000000001",
          pool_id: "bbbbbbbb-bbbb-4bbb-8bbb-000000000001"
        },
        destination: %{host_id: pool.host_id, placement_id: spec.id, pool_id: pool.id},
        workload:
          Map.take(command, [
            :architecture,
            :image_id,
            :profile,
            :slot,
            :vcpu,
            :memory_bytes,
            :disk_bytes
          ]),
        stream: %{source_dataset_guid: "100", to_guid: "200"}
      }

      request = %{
        id: command.id,
        descriptor: descriptor,
        generation: 1,
        expires_at: System.system_time(:second) + 180,
        timeout_ms: 120_000
      }

      runtime = %Lilly.Control.Config{
        client: %Client{
          host_id: pool.host_id,
          base_url: "https://fixture.invalid",
          token: "unused"
        },
        state_dir: state,
        cgroup_path: "/sys/fs/cgroup/lilly.slice",
        pools: [pool],
        execution: config
      }

      {:ok, boot_id} = ReadinessProbe.execute(runtime, store, request)
      true = OverallsProtocol.uuid?(boot_id)

      {:ok, ^boot_id} = contended_probe(runtime, store, %{request | timeout_ms: 5000})

      {:error, :execution_unavailable} =
        contended_probe(runtime, store, %{request | timeout_ms: 50})

      {:ok, ^boot_id} = ReadinessProbe.execute(runtime, store, request)

      for bad <- [
            %{request | generation: 2},
            %{request | id: "88888888-8888-4888-8888-000000000104"},
            %{request | expires_at: System.system_time(:second) - 1}
          ] do
        {:error, _} = ReadinessProbe.execute(runtime, store, bad)
      end

      :ok = Driver.stop(config, pool, spec, execution_epoch: 2, generation: 2)
      {:error, _} = ReadinessProbe.execute(runtime, store, request)
      delete(config, pool, spec, System.monotonic_time(:millisecond) + 60_000)
    after
      Lock.release(lock)
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification;recovery] readiness-native-lock-contention
  # A probe MUST survive a briefly held real placement lock, retain its guest
  # boot identity, and fail within its original budget when the lock outlasts it.
  # The holder MUST release ownership even if the assertion fails.
  @spec contended_probe(
          Lilly.Control.Config.t(),
          Store.t(),
          OverallsProtocol.RelocationReadiness.command()
        ) :: {:ok, String.t()} | {:error, atom()}
  defp contended_probe(runtime, store, request) do
    parent = self()

    directory =
      Path.join([
        runtime.execution.state_dir,
        request.descriptor.destination.placement_id,
        "lock"
      ])

    holder =
      Task.async(fn ->
        {:ok, lock} = Lock.acquire(directory)

        try do
          send(parent, {:placement_locked, self()})

          receive do
            :probe_starting -> Process.sleep(250)
          after
            2000 -> raise "readiness fixture did not start its probe"
          end
        after
          :ok = Lock.release(lock)
        end
      end)

    try do
      receive do
        {:placement_locked, pid} when pid == holder.pid ->
          send(pid, :probe_starting)
          ReadinessProbe.execute(runtime, store, request)
      after
        2000 -> raise "readiness fixture did not acquire its placement lock"
      end
    after
      Task.await(holder, 5000)
    end
  end

  # @cc [owner:ghuntley,label:verification] readiness-cleanup-retries-same-authority
  # Unconfirmed native deletion MUST retry the identical epoch/generation within
  # a fixed deadline, as the effect runtime does. Only production Driver.delete
  # success may finish cleanup; no direct dataset removal may bypass its checks.
  @spec delete(Lilly.VM.Config.t(), Lilly.Host.Pool.t(), Lilly.VM.Spec.t(), integer()) :: :ok
  defp delete(config, pool, spec, deadline) do
    case Driver.delete(config, pool, spec, execution_epoch: 2, generation: 3) do
      :ok ->
        :ok

      {:error, :zfs_dataset_cleanup_unconfirmed} ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("readiness fixture cleanup remained unconfirmed")

        Process.sleep(1000)
        delete(config, pool, spec, deadline)
    end
  end

  @spec running(Lilly.VM.Config.t(), Lilly.Host.Pool.t(), Lilly.VM.Spec.t(), integer()) ::
          :ok | nil
  defp running(config, pool, spec, deadline) do
    unless Observation.running?(config, pool, spec) do
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("readiness fixture VMM did not start")

      Process.sleep(100)
      running(config, pool, spec, deadline)
    end
  end
end
