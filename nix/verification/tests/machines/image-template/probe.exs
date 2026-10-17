# @cc [owner:ghuntley,label:verification] native-template-production-path
# The disposable fixture MUST use real ZFS, production template state machines,
# pool accounting and Disk preparation. Synthetic bytes establish storage
# behavior only; boot and certified SSH require the separate real-guest fleet.
# A validated warm template MUST carry the ready record/incarnation UUIDs into
# the copy callback; the verified uncached path MUST carry neither UUID nor lease.
defmodule ImageTemplateFixture do
  alias Lilly.Host.{Image, ImageTemplate, Lock, Pool, PoolSnapshot, Storage}
  alias Lilly.Host.{ZFS, ZFSDataset}
  alias Lilly.VM.{Disk, Spec, WorkloadBundle}

  @spec run() :: :ok
  def run do
    {:ok, _} = Application.ensure_all_started(:lilly)
    number = String.to_integer(System.fetch_env!("TEMPLATE_IMAGE"))
    true = number in 1..12
    source = "/run/template-source-#{number}"
    seed(source, number)
    {:ok, image} = Image.load(source)
    {:ok, identity} = ZFS.inspect_path("/pool")

    {:ok, pool} =
      Pool.new("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "/pool", identity.filesystem_id,
        storage: OverallsProtocol.Storage.encode(identity.storage),
        host_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        template_budget_bytes: if(number == 10, do: 209_715_200, else: 5_000_000)
      )

    action = System.fetch_env!("TEMPLATE_ACTION")
    {:ok, lock} = Lock.acquire("/run/template-placement-#{number}")

    if number == 10 and action == "copy" do
      {:os_pid, owner} = Port.info(lock, :os_pid)
      File.write!("/run/template-copy-owner", Integer.to_string(owner))
    end

    try do
      case action do
        "ensure" ->
          :ok = ImageTemplate.ensure(pool, image)

        "warm" ->
          :ok =
            ImageTemplate.with_image(pool, image, fn sealed ->
              true = sealed.id == image.id
              true = sealed.path != image.path
              true = OverallsProtocol.uuid?(sealed.template_record_id)
              true = OverallsProtocol.uuid?(sealed.template_incarnation)
              true = is_binary(sealed.source_lease)
              :ok
            end)

        "uncached" ->
          uncached_pool = %{pool | template_budget_bytes: 1}
          :uncached = ImageTemplate.ensure(uncached_pool, image)

          :ok =
            ImageTemplate.with_image(uncached_pool, image, fn verified ->
              nil = verified.source_lease
              nil = verified.template_record_id
              nil = verified.template_incarnation
              :ok
            end)

        "copy" ->
          :ok = retry(fn -> Disk.prepare(pool, image, spec(pool, image, number)) end)

        "ready" ->
          :ok = retry(fn -> Disk.ready(pool, spec(pool, image, number)) end)

          {:ok, _} =
            WorkloadBundle.load(
              ZFSDataset.directory(pool, spec(pool, image, number)),
              spec(pool, image, number)
            )

        "refuse" ->
          {:error, _} = ImageTemplate.with_image(pool, image, fn _ -> raise "unsafe callback" end)

        "audit" ->
          :ok = retry(fn -> audit(pool) end)

        "audit-refuse" ->
          {:error, _} = audit(pool)

        "lease" ->
          :ok =
            ImageTemplate.with_image(pool, image, fn _ ->
              File.write!("/run/template-reader-ready", "")

              receive do
                :never -> :ok
              after
                120_000 -> :ok
              end
            end)

        "expect-budget-refusal" ->
          :uncached = ImageTemplate.ensure(pool, image)

        # ADR-0152 evidence: the pool-locked part of Disk.prepare (which is
        # exactly ZFSDataset.prepare/3), timed, with each zfs, zpool and
        # findmnt invocation logged by the trace shims.
        "prepare-trace" ->
          spec = spec(pool, image, number)
          # A usage-only race reports storage_busy (the executor retries it);
          # retry with a fresh trace so the count covers one successful prepare.
          held = traced_prepare(pool, spec, System.monotonic_time(:millisecond) + 30_000)
          File.rename!("/run/template-trace.log", "/run/template-trace-result")
          IO.puts("prepare_us=#{held}")

        # Only this run's image stays configured; every other template retires.
        "retire-unconfigured" ->
          {:ok, retired} = ImageTemplate.retire_unconfigured(pool, [image.id])
          IO.puts("retired=#{retired}")

        "delete-vm" ->
          :ok = retry(fn -> Disk.delete(pool, spec(pool, image, number)) end)

        "audit-refuse-any" ->
          {:ok, _} =
            Storage.locked(pool, fn ->
              with {:ok, snapshot} <- snapshot(pool),
                   do: ZFSDataset.classify_allocations(pool, snapshot)
            end)

        "audit-any" ->
          :ok =
            retry(fn ->
              Storage.locked(pool, fn ->
                # Print only the closed rejection stage so failures are diagnosable.
                case snapshot(pool) do
                  {:ok, snapshot} ->
                    case ZFSDataset.classify_allocations(pool, snapshot) do
                      {:ok, _} -> :ok
                      {:error, check} -> IO.puts("allocation rejection: #{check}") && {:error, check}
                    end

                  {:error, reason} = error ->
                    IO.puts("observation rejection: #{reason}")
                    error
                end
              end)
            end)
      end
    after
      Lock.release(lock)
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification] template-fixture-preserves-observation-refusals
  # Only storage_busy may retry, under one fixed deadline. Native identity,
  # ownership and corruption refusals MUST remain failures.
  @spec retry((-> :ok | {:error, atom()}), integer()) :: :ok | {:error, atom()}
  defp retry(fun, deadline \\ System.monotonic_time(:millisecond) + 30_000) do
    case fun.() do
      {:error, :storage_busy} = error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          retry(fun, deadline)
        else
          error
        end

      result ->
        result
    end
  end

  @spec traced_prepare(Pool.t(), Spec.t(), integer()) :: integer()
  defp traced_prepare(pool, spec, deadline) do
    File.write!("/run/template-trace.log", "")
    started = System.monotonic_time(:microsecond)
    result = Storage.locked(pool, fn -> ZFSDataset.prepare(pool, spec) end)
    held = System.monotonic_time(:microsecond) - started

    case result do
      :ok ->
        held

      {:error, :storage_busy} ->
        true = System.monotonic_time(:millisecond) < deadline
        Process.sleep(200)
        traced_prepare(pool, spec, deadline)
    end
  end

  @spec spec(Pool.t(), Image.t(), pos_integer()) :: Spec.t()
  defp spec(pool, image, number) do
    # Subtests address several placements built from one image.
    number = String.to_integer(System.get_env("TEMPLATE_PLACEMENT", to_string(number)))
    id = "dddddddd-dddd-4ddd-8ddd-" <> String.pad_leading(to_string(number), 12, "0")

    {:ok, spec} =
      Spec.new(%{
        id: id,
        image_id: image.id,
        pool_id: pool.id,
        profile: :oss,
        slot: number + 2,
        vcpu: 1,
        memory_bytes: 536_870_912,
        disk_bytes: 2_147_483_648
      })

    spec
  end

  @spec audit(Pool.t()) :: :ok | {:error, atom()}
  defp audit(pool) do
    Storage.locked(pool, fn ->
      with {:ok, snapshot} <- snapshot(pool),
           {:ok, credits} <- ZFSDataset.allocations(pool, snapshot) do
        true = Map.keys(credits) in [[], ["dddddddd-dddd-4ddd-8ddd-000000000001"]]
        :ok
      end
    end)
  end

  # One pool-locked PoolSnapshot (ADR-0152); a usage-only race stays
  # storage_busy so only that outcome is retried.
  @spec snapshot(Pool.t()) :: {:ok, PoolSnapshot.t()} | {:error, term()}
  defp snapshot(pool) do
    case PoolSnapshot.read(pool) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, {:observe, reason}} -> {:error, reason}
      {:error, stage} -> {:error, stage}
    end
  end

  @spec seed(Path.t(), pos_integer()) :: :ok
  defp seed(path, number) do
    unless File.exists?(path) do
      File.mkdir!(path)
      File.chmod!(path, 0o700)

      artifacts =
        Map.new(~w(kernel initrd rootfs), fn name ->
          size = if number == 10, do: 134_217_728, else: 4_194_304

          bytes =
            if name == "rootfs",
              do: :binary.copy(<<number>>, size),
              else: "fixture-#{name}-#{number}"

          file = Path.join(path, if(name == "rootfs", do: "rootfs.ext4", else: name))
          File.write!(file, bytes)
          File.chmod!(file, 0o444)

          {name,
           %{
             "bytes" => byte_size(bytes),
             "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
           }}
        end)

      manifest =
        Map.merge(artifacts, %{
          "version" => 4,
          "workspace_source_version" => nil,
          "architecture" => "x86_64",
          "boot_args" => "console=ttyS0",
          "minimum_memory_bytes" => 536_870_912,
          "minimum_disk_bytes" => 2_147_483_648
        })

      File.write!(Path.join(path, "manifest.json"), JSON.encode!(manifest))
      File.chmod!(Path.join(path, "manifest.json"), 0o444)
    end

    :ok
  end
end

:ok = ImageTemplateFixture.run()
