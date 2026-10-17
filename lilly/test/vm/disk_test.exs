defmodule Lilly.VM.DiskTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.{Lock, Pool, Storage, ZFSDataset}
  alias Lilly.VM.{Disk, Spec, WorkloadBundle}
  @moduletag :tmp_dir

  # @cc [owner:ghuntley,label:verification] retained-disk-real-boundary-regression
  # These checks MUST execute the compiled production Disk and Storage modules.
  # Synthetic dataset outcomes belong only to an isolated BEAM peer; they MUST
  # NOT replace modules in the test runner or establish native ZFS acceptance.
  # Each call MUST release the actual pool lock and invoke dataset verification
  # once; busy and invalid identity MUST NOT read a boot bundle.
  test "retained disk readiness preserves native busy without replaying verification", context do
    File.chmod!(context.tmp_dir, 0o700)

    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        args: [~c"+S", ~c"2:2", ~c"-pa"] ++ :code.get_path()
      })

    try do
      assert {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])

      for module <- [Disk, Storage, Lock, Lilly.Host.PoolQueue, WorkloadBundle] do
        assert :peer.call(peer, :code, :get_object_code, [module]) ==
                 :code.get_object_code(module)
      end

      # Storage takes a PoolQueue turn before the native lock (ADR-0176).
      assert {:ok, _} =
               :peer.call(peer, GenServer, :start, [
                 Lilly.Host.PoolQueue,
                 :ok,
                 [name: Lilly.Host.PoolQueue]
               ])

      install_dataset_boundary(peer)
      pool = %Pool{id: Lilly.UUID.generate(), path: context.tmp_dir, filesystem_id: "zfs:1:2"}
      {:ok, network} = Lilly.Network.Guest.new(Lilly.UUID.generate(), :customer, 2)

      spec = %Spec{
        id: Lilly.UUID.generate(),
        image_id: "sha256:" <> String.duplicate("a", 64),
        pool_id: pool.id,
        network: network,
        vcpu: 1,
        memory_bytes: 1_073_741_824,
        disk_bytes: 4_294_967_296
      }

      for {native, expected, bundle_reads} <- [
            {{:error, :storage_busy}, {:error, :storage_busy}, 0},
            {{:error, :zfs_disk_not_ready}, {:error, :disk_not_ready}, 0},
            {:ok, {:error, :disk_not_ready}, 1}
          ] do
        assert :ok = :peer.call(peer, :persistent_term, :put, [{ZFSDataset, :result}, native])
        assert :ok = :peer.call(peer, :persistent_term, :put, [{ZFSDataset, :calls}, 0])
        assert :ok = :peer.call(peer, :persistent_term, :put, [{ZFSDataset, :directories}, 0])
        result = :peer.call(peer, Disk, :ready, [pool, spec])

        assert :peer.call(peer, :persistent_term, :get, [{ZFSDataset, :calls}]) == 1

        assert :peer.call(peer, :persistent_term, :get, [{ZFSDataset, :directories}]) ==
                 bundle_reads

        # Acquisition from this independent BEAM proves release even when the
        # protected callback itself returns storage_busy.
        assert {:ok, successor} = Lock.acquire(Path.join(pool.path, ".lilly-storage"))
        assert :ok = Lock.release(successor)
        assert result == expected
      end
    after
      monitor = Process.monitor(peer)
      :peer.stop(peer)
      assert_receive {:DOWN, ^monitor, :process, ^peer, _}, 5000
    end
  end

  @spec install_dataset_boundary(pid()) :: :ok
  defp install_dataset_boundary(peer) do
    # Only the disposable peer replaces this native boundary. The production
    # modules compared above and all modules in the runner retain their bytecode.
    :peer.call(peer, :code, :purge, [ZFSDataset])
    :peer.call(peer, :code, :delete, [ZFSDataset])

    quoted =
      quote do
        defmodule Lilly.Host.ZFSDataset do
          @spec ready(Lilly.Host.Pool.t(), Lilly.VM.Spec.t()) :: :ok | {:error, atom()}
          def ready(_pool, _spec) do
            true = is_struct(Lilly.Host.Lock.current(), Lilly.Host.Lease)

            :persistent_term.put(
              {__MODULE__, :calls},
              :persistent_term.get({__MODULE__, :calls}) + 1
            )

            :persistent_term.get({__MODULE__, :result})
          end

          @spec directory(Lilly.Host.Pool.t(), Lilly.VM.Spec.t()) :: Path.t()
          def directory(pool, spec) do
            :persistent_term.put(
              {__MODULE__, :directories},
              :persistent_term.get({__MODULE__, :directories}) + 1
            )

            # The real bundle loader must reject absent metadata, without
            # inventing root-owned artifacts in an unprivileged fixture.
            Path.join([pool.path, "vms", spec.id])
          end
        end
      end

    # This peer deliberately replaces exactly this native boundary. Suppress
    # its expected module-conflict warning only while compiling the replacement;
    # the test runner and all other warning checks retain their normal settings.
    previous = :peer.call(peer, Code, :compiler_options, [])

    try do
      :peer.call(peer, Code, :compiler_options, [[ignore_module_conflict: true]])
      assert [{ZFSDataset, _}] = :peer.call(peer, Code, :compile_quoted, [quoted])
    after
      :peer.call(peer, Code, :compiler_options, [previous])
    end

    :ok
  end
end
