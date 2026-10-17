defmodule ZFSGuestSourceFixture do
  @moduledoc false
  alias Lilly.Host.{Lock, PrivateFiles, Storage}
  alias Lilly.Transfer.{Key, PermitJournal, Source, SourceExport, SourceSnapshots}
  alias Lilly.Control.{Client, Store}
  alias Lilly.Lifecycle.Journal
  alias Lilly.VM.{Boot, Provisioning}
  alias OverallsProtocol.RelocationSource, as: Wire

  # @cc [owner:ghuntley,label:verification] source-request-real-guest-boundary
  # This disposable fixture MUST use real driver intent, native snapshots and
  # permit journals while the guest is running/stopped as claimed. Its synthetic
  # Marshall request and local destination-key fixture MUST NOT establish actual
  # cross-host control distribution, capacity admission or guest relocation.
  @spec run(
          Lilly.VM.Config.t(),
          Lilly.Host.Pool.t(),
          Lilly.VM.Spec.t(),
          pos_integer(),
          String.t()
        ) ::
          :ok
  def run(config, pool, spec, generation, action) do
    root = "/var/lib/lilly/transfers"
    state = "/var/lib/lilly/source-control"
    fixture = "/var/lib/lilly/source-fixture/" <> spec.id
    :ok = PrivateFiles.directory(root)
    :ok = PrivateFiles.directory(Path.dirname(fixture))
    :ok = PrivateFiles.directory(fixture)

    prefix =
      if action == "source-probe",
        do: "99999999-9999-4999-8999-",
        else: "ffffffff-ffff-4fff-8fff-"

    relocation = prefix <> String.slice(spec.id, -12, 12)

    if action == "source-cleanup" do
      :ok = SourceExport.revoke(root, pool.host_id, relocation)

      {:ok, :clean} =
        Lilly.VM.Driver.with_transfer_source(config, pool, spec, {1, generation}, :stopped, fn ->
          Storage.locked(pool, fn ->
            :ok = SourceSnapshots.cleanup(pool, spec, relocation, 1)
            {:ok, :clean}
          end)
        end)
    else
      {:ok, lock} = Lock.acquire(state)

      try do
        {:ok, store} = Store.open(state, pool.host_id)

        # Only the probe and the refusal case act on a running guest; every
        # snapshot or grant needs the stopped source of ADR-0155.
        kind =
          if action in ["source-probe", "source-reject"],
            do: :start,
            else: :stop

        command = %{
          owner_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
          id:
            "88888888-8888-4888-8888-" <>
              String.pad_leading(to_string(spec.network.slot * 100 + generation), 12, "0"),
          vm_id: spec.id,
          placement_id: spec.id,
          execution_epoch: 1,
          host_id: pool.host_id,
          pool_id: pool.id,
          generation: generation,
          kind: kind,
          architecture: :x86_64,
          image_id: spec.image_id,
          profile: spec.network.profile,
          slot: spec.network.slot,
          vcpu: spec.vcpu,
          memory_bytes: spec.memory_bytes,
          disk_bytes: spec.disk_bytes
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
          transfer_state_dir: root
        }

        if action == "source-probe" do
          # Match the runtime's isolated effect task: it must not inherit the
          # fixture's control-store ownership helper as a pool/activity lock.
          Task.async(fn ->
            if System.get_env("ZFS_GUEST_UBUNTU") == "1" do
              {:error, :readiness_timeout} =
                Lilly.VM.Driver.provisioned(config, pool, spec,
                  execution_epoch: 1,
                  generation: generation
                )
            end

            # A concurrent source effect owns the same placement lock. Reconciliation
            # must retain its observation instead of publishing an identity failure.
            {:ok, placement_lock} = Lock.acquire(Path.join([config.state_dir, spec.id, "lock"]))
            history = %{running_epoch: 1, running_generation: generation}

            readiness =
              try do
                {:retry, :execution_unavailable} =
                  Task.async(fn -> Lilly.VM.Executor.reconcile(runtime, command, history) end)
                  |> Task.await(10_000)

                source_readiness(config, spec, generation)
              after
                :ok = Lock.release(placement_lock)
              end

            if readiness == :ready do
              {:ok, %{state: :running}} = Lilly.VM.Executor.reconcile(runtime, command, history)
            end

            probe(runtime, store, request(fixture, relocation, command, action))
          end)
          |> Task.await(300_000)
        else
          if action == "source-retire" do
            Task.async(fn -> retire(runtime, store, fixture, command, spec) end)
            |> Task.await(300_000)
          else
            request = request(fixture, relocation, command, action)

            if action == "source-reject" do
              for bad <- [
                    put_in(request.intent.source_epoch, 2)
                    |> put_in([:intent, :destination_epoch], 3),
                    %{request | generation: generation + 1},
                    %{request | expires_at: System.system_time(:second) - 1},
                    # A well-formed request is still refused: the guest runs.
                    request
                  ] do
                {:error, _} = Source.execute(runtime, store, bad)
              end

              {:error, :source_authority_unconfirmed} =
                Lilly.VM.Driver.with_transfer_source(
                  config,
                  pool,
                  spec,
                  {1, generation},
                  :stopped,
                  fn ->
                    raise "running source accepted final work"
                  end
                )

              true = Lilly.VM.Observation.running?(config, pool, spec)
            else
              {:ok, result} = Source.execute(runtime, store, request)
              {:ok, ^result} = Source.execute(runtime, store, request)

              {:ok, grant} =
                PermitJournal.lookup(
                  root,
                  pool.host_id,
                  relocation,
                  request.public_key,
                  System.system_time(:second)
                )

              true = grant.descriptor == result.descriptor and grant.revision == request.revision

              {:ok, _} =
                Storage.locked(pool, fn ->
                  SourceSnapshots.export(
                    pool,
                    OverallsProtocol.Relocation.encode_descriptor(result.descriptor)
                  )
                end)

              :ok =
                PrivateFiles.write(
                  fixture,
                  "request.json",
                  JSON.encode!(Wire.encode_command(request))
                )

              :ok =
                PrivateFiles.write(
                  fixture,
                  "result.json",
                  JSON.encode!(Wire.encode_result(result))
                )
            end
          end
        end
      after
        Lock.release(lock)
      end
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification;security] source-probe-readiness-prerequisite
  # Post-release running reconciliation MUST require verified readiness for the
  # current locked boot. Isolated Ubuntu without Audi roster authority MUST
  # time out through the real completion API, remain awaiting_ssh and MUST NOT
  # publish readiness. Both cases
  # retain the lock-contention retry and real probe/process/snapshot assertions.
  @spec source_readiness(Lilly.VM.Config.t(), Lilly.VM.Spec.t(), pos_integer()) ::
          :ready | :awaiting_ssh
  defp source_readiness(config, spec, generation) do
    directory = Path.join(config.state_dir, spec.id)
    {:ok, boot} = Boot.current(directory, spec.id, {1, generation})

    case Provisioning.status(config, spec, boot) do
      {:ready, _boot_id} ->
        true = System.get_env("ZFS_GUEST_UBUNTU") != "1"
        :ready

      {:wait, _remaining} ->
        true = System.get_env("ZFS_GUEST_UBUNTU") == "1"

        {:ok, %{state: :awaiting_ssh}} =
          Journal.load(Lilly.Lifecycle.Provisioning, directory, "provisioning.json")

        :awaiting_ssh
    end
  end

  # @cc [owner:ghuntley,label:verification] source-probe-native-running-authority
  # The probe fixture MUST exercise the production effect with a real running
  # placement and retained control intent. Exact retries must retain one grant;
  # stale generation, changed workload, expired lease and revoked grants must
  # fail. A successful grant MUST NOT authorize a ZFS export. The Python driver
  # independently checks unchanged guest processes and absent snapshots.
  defp probe(runtime, store, source) do
    request =
      source
      |> Map.drop([:to_guid])
      |> Map.merge(%{phase: :grant, challenge: Lilly.UUID.generate(), source_endpoint: nil})

    {:ok, ^request} =
      request
      |> OverallsProtocol.RelocationProbe.encode_command()
      |> OverallsProtocol.RelocationProbe.command()

    {:ok, result} = Lilly.Transfer.Probe.execute(runtime, store, request)
    true = OverallsProtocol.RelocationProbe.matches?(request, result)
    {:ok, ^result} = Lilly.Transfer.Probe.execute(runtime, store, request)

    {:ok, grant} =
      PermitJournal.lookup_probe(
        runtime.transfer_state_dir,
        store.host_id,
        request.intent.relocation_id,
        request.public_key,
        request.challenge,
        System.system_time(:second)
      )

    true = grant.intent == request.intent and grant.revision == request.revision

    {:error, _} =
      PermitJournal.lookup(
        runtime.transfer_state_dir,
        store.host_id,
        request.intent.relocation_id,
        request.public_key,
        System.system_time(:second)
      )

    for bad <- [
          %{request | generation: request.generation + 1},
          put_in(request.intent.workload.vcpu, request.intent.workload.vcpu + 1),
          %{request | expires_at: System.system_time(:second) - 1}
        ] do
      {:error, :probe_unconfirmed} = Lilly.Transfer.Probe.execute(runtime, store, bad)
    end

    :ok =
      SourceExport.revoke(runtime.transfer_state_dir, store.host_id, request.intent.relocation_id)

    {:error, :probe_unconfirmed} = Lilly.Transfer.Probe.execute(runtime, store, request)
  end

  # @cc [owner:ghuntley,label:verification] source-retirement-native-retry
  # The retirement fixture MUST retain bytes after interrupted deletion intent,
  # then verify production cleanup and retry after metadata moves to its tombstone.
  # Synthetic control does not establish Marshall-driven guest movement.
  defp retire(runtime, store, fixture, command, spec) do
    {:ok, result} =
      fixture |> Path.join("result.json") |> File.read!() |> JSON.decode!() |> Wire.result()

    d = result.descriptor

    request = %{
      id: d.relocation_id,
      descriptor: d,
      generation: command.generation,
      expires_at: System.system_time(:second) + 180
    }

    [pool] = runtime.pools

    for bad <- [
          %{request | generation: request.generation + 1},
          %{request | expires_at: System.system_time(:second) - 1}
        ] do
      {:error, _} = Lilly.Transfer.SourceCleanup.execute(runtime, store, bad)
    end

    :ok = SourceExport.revoke(runtime.transfer_state_dir, pool.host_id, request.id)

    {:error, _} =
      Lilly.VM.Driver.retire_transfer_source(
        runtime.execution,
        pool,
        spec,
        {command.execution_epoch, command.generation},
        fn -> {:error, :injected_interruption} end
      )

    true = File.regular?(Lilly.VM.Disk.path(pool, spec))

    {:error, _} =
      Lilly.Transfer.SourceCleanup.execute(
        runtime,
        store,
        put_in(request.descriptor.stream.source_dataset_guid, "999")
      )

    true = File.regular?(Lilly.VM.Disk.path(pool, spec))
    {:ok, :deleted} = Lilly.Transfer.SourceCleanup.execute(runtime, store, request)
    {:ok, :deleted} = Lilly.Transfer.SourceCleanup.execute(runtime, store, request)
    {:error, :enoent} = File.lstat(Lilly.VM.Disk.path(pool, spec))
  end

  defp request(fixture, relocation, command, action)
       when action == "source-renew" do
    {:ok, old} =
      fixture |> Path.join("request.json") |> File.read!() |> JSON.decode!() |> Wire.command()

    {:ok, result} =
      fixture |> Path.join("result.json") |> File.read!() |> JSON.decode!() |> Wire.result()

    true = old.intent.relocation_id == relocation

    next = %{
      old
      | id: Lilly.UUID.generate(),
        generation: command.generation,
        revision: old.revision + 1,
        expires_at: System.system_time(:second) + 240
    }

    # A renewal pins the snapshot GUID the first grant returned.
    %{next | to_guid: result.descriptor.stream.to_guid}
  end

  defp request(_, relocation, command, _action) do
    destination = %{
      host_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      placement_id: "cccccccc-cccc-4ccc-8ccc-" <> String.slice(command.placement_id, -12, 12),
      pool_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    }

    :ok = PrivateFiles.directory("/var/lib/lilly/source-peer")

    {:ok, public} =
      Key.ensure(
        "/var/lib/lilly/source-peer",
        destination.host_id,
        relocation,
        destination.placement_id
      )

    %{
      id: Lilly.UUID.generate(),
      generation: command.generation,
      revision: 1,
      expires_at: System.system_time(:second) + 180,
      public_key: public,
      to_guid: nil,
      intent: %{
        relocation_id: relocation,
        vm_id: command.vm_id,
        source_epoch: 1,
        destination_epoch: 2,
        source: %{
          placement_id: command.placement_id,
          host_id: command.host_id,
          pool_id: command.pool_id
        },
        destination: destination,
        workload:
          Map.take(command, [
            :image_id,
            :architecture,
            :profile,
            :slot,
            :vcpu,
            :memory_bytes,
            :disk_bytes
          ])
      }
    }
  end
end
