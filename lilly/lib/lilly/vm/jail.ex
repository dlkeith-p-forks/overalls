defmodule Lilly.VM.Jail do
  @moduledoc "Disposable jail with placement-local boot mounts and persistent writable disks."
  require Lilly.Events
  alias Lilly.Host.{Command, Pool, PrivateFiles, ZFSDataset}
  alias OverallsProtocol.WorkloadBundle, as: BundleMetadata
  alias Lilly.VM.{Boot, CheckpointStorage, Disk, Spec, WorkloadBundle}

  @spec base(Pool.t()) :: Path.t()
  def base(pool), do: Path.join(pool.path, ".lilly-jails")
  @spec root(Pool.t(), Spec.t()) :: Path.t()
  def root(pool, spec), do: Path.join([base(pool), "firecracker", spec.id, "root"])

  @doc "Whether every VM UUID leaves room for the API's Linux Unix socket address."
  @spec supports_pool?(Pool.t()) :: boolean()
  def supports_pool?(pool) do
    path = Path.join([base(pool), "firecracker", String.duplicate("0", 36), "root", "api.sock"])
    byte_size(path) < 108
  end

  @doc "Requires a matching durable VM claim and confirmed empty VM cgroup."
  # @cc [owner:ghuntley,label:isolation;security] firmware-jail-pci-metadata
  # For a firmware bundle prepare/4 MUST bind-mount only the firmware read-only,
  # write the boot identity as a root-owned read-only `metadata.json` that
  # Firecracker loads into MMDS before the guest runs, and return the loaded
  # bundle so the unit start can select the PCI transport. Kernel bundles keep
  # their kernel and initrd mounts and command-line identity and never receive
  # MMDS metadata.
  @spec prepare(Pool.t(), Spec.t(), Boot.t(), OverallsProtocol.uuid() | nil) ::
          {:ok, WorkloadBundle.t()} | {:error, :jail_prepare_failed}
  def prepare(pool, spec, boot, vm_id \\ nil) do
    bundle_directory = ZFSDataset.directory(pool, spec)

    with true <- boot.placement_id == spec.id,
         :ok <- PrivateFiles.directory(base(pool)),
         :ok <- PrivateFiles.directory(Path.join(base(pool), "firecracker")),
         :ok <- PrivateFiles.directory(Path.dirname(root(pool, spec))),
         :ok <- cleanup(pool, spec),
         :ok <- PrivateFiles.directory(root(pool, spec)),
         {:ok, bundle} <- WorkloadBundle.load(bundle_directory, spec),
         :ok <- mount_boot_artifacts(bundle_directory, pool, spec, bundle),
         :ok <- mount_drives(pool, spec),
         :ok <- mount_checkpoints(pool, spec),
         :ok <- write_metadata(pool, spec, bundle, boot),
         :ok <-
           PrivateFiles.write(
             root(pool, spec),
             "firecracker.json",
             JSON.encode!(configuration(bundle, spec, boot))
           ),
         :ok <- File.chmod(Path.join(root(pool, spec), "firecracker.json"), 0o444) do
      {:ok, bundle}
    else
      _ ->
        if vm_id,
          do:
            Lilly.Events.emit("lilly.jail_prepare_failed",
              vm_id: vm_id,
              placement_id: spec.id,
              reason: :jail_prepare_failed
            )

        {:error, :jail_prepare_failed}
    end
  end

  # @cc [owner:ghuntley,label:recovery] guest-flushes-reach-backing-storage
  # All persistent drives MUST explicitly use Writeback and the Sync I/O engine, so guest
  # flush requests are handled rather than relying on Firecracker's Unsafe cache default.

  # @cc [owner:ghuntley,label:recovery] jail-readiness-binds-persisted-boot
  # configuration/3 MUST pass the caller's durably prepared boot identity into the
  # guest: on the kernel command line with a jail-local vsock endpoint for a kernel
  # bundle, or through the MMDS metadata file (metadata/3) for a firmware bundle,
  # which boots the firmware over virtio-pci. Only Windows firmware receives the
  # Hyper-V CPU template; native FreeBSD and illumos firmware use the default CPU
  # model. A firmware bundle gets the jail-local vsock endpoint only when its agent
  # set speaks a vsock protocol (OverallsProtocol.GuestAgents.vsock?/1); an
  # agentless bundle has no vsock device. The caller MUST supply a Boot matching
  # this placement and current launch intent, never peer-provided boot data.
  @spec configuration(WorkloadBundle.t(), Spec.t(), Boot.t()) :: map()
  def configuration(%{boot_kind: :kernel} = bundle, spec, boot) do
    boot_source = %{
      "kernel_image_path" => "/kernel",
      "boot_args" =>
        Map.get(bundle, :boot_args, "") <>
          " lilly.ipv4=" <>
          spec.network.address <>
          " lilly.placement=" <>
          boot.placement_id <>
          " lilly.execution_epoch=" <>
          Integer.to_string(boot.execution_epoch) <>
          " lilly.boot_challenge=" <>
          boot.boot_challenge <> git_identity_argument(spec)
    }

    boot_source =
      if is_integer(Map.get(bundle, :initrd_bytes)),
        do: Map.put(boot_source, "initrd_path", "/initrd"),
        else: boot_source

    transport =
      if OverallsProtocol.GuestAgents.vsock?(bundle.guest_agents),
        do: %{"guest_cid" => 3, "uds_path" => "/v.sock"},
        else: nil

    config = Map.merge(shared_configuration(spec), %{"boot-source" => boot_source})
    if transport, do: Map.put(config, "vsock", transport), else: config
  end

  def configuration(%{boot_kind: :firmware} = bundle, spec, _boot) do
    vsock =
      if OverallsProtocol.GuestAgents.vsock?(bundle.guest_agents),
        do: %{"vsock" => %{"guest_cid" => 3, "uds_path" => "/v.sock"}},
        else: %{}

    firmware =
      shared_configuration(spec)
      |> Map.merge(%{
        "boot-source" => %{"kernel_image_path" => "/firmware"},
        "mmds-config" => %{"version" => "V2", "network_interfaces" => ["eth0"]}
      })
      |> maybe_hyperv(bundle)

    Map.merge(firmware, vsock)
  end

  defp shared_configuration(spec) do
    %{
      "drives" =>
        Enum.map(Spec.drives(spec), fn drive ->
          %{
            "drive_id" => if(drive.root, do: "root", else: "data"),
            "path_on_host" => "/" <> drive.name,
            "is_root_device" => drive.root,
            "is_read_only" => false,
            "cache_type" => "Writeback",
            "io_engine" => "Sync"
          }
        end),
      "machine-config" => %{
        "vcpu_count" => spec.vcpu,
        "mem_size_mib" => div(spec.memory_bytes, 1_048_576),
        "smt" => false
      },
      "network-interfaces" => [
        %{
          "iface_id" => "eth0",
          "host_dev_name" => spec.network.tap,
          "guest_mac" => spec.network.mac
        }
      ]
    }
  end

  # Existing version-5 firmware is the Windows/Hyper-V image. Native firmware
  # images carry their operating system in the bundle and use Firecracker's
  # default CPU model; retaining the old default keeps v5 bundle markers valid.
  defp maybe_hyperv(configuration, bundle) do
    if Map.get(bundle, :os, :windows) == :windows,
      do: Map.put(configuration, "cpu-config", %{"hyperv" => true}),
      else: configuration
  end

  # @cc [owner:ghuntley,label:security;recovery] firmware-metadata-is-the-kernel-command-line
  # metadata/3 MUST carry exactly the boot identity a kernel guest receives on its
  # command line (placement, execution epoch, boot challenge, IPv4 address) plus the
  # static network facts a firmware guest cannot derive (prefix length, gateway, MAC)
  # under the single `lilly` key with a version. It MUST NOT include the generation,
  # which advances without a reboot, nor any credential or host path. An optional validated public Git identity
  # MUST use the same versioned document on both boot transports.
  @spec metadata(WorkloadBundle.t(), Spec.t(), Boot.t()) :: map()
  def metadata(%{boot_kind: :firmware}, spec, boot) do
    %{
      "lilly" =>
        %{
          "version" => 1,
          "placement" => boot.placement_id,
          "execution_epoch" => boot.execution_epoch,
          "boot_challenge" => boot.boot_challenge,
          "ipv4" => spec.network.address,
          "prefix_length" => 32,
          "gateway" => spec.network.gateway,
          "mac" => spec.network.mac
        }
        |> maybe_git_identity(spec)
    }
  end

  @spec git_identity_argument(Spec.t()) :: String.t()
  defp git_identity_argument(%{git_identity: nil}), do: ""

  defp git_identity_argument(%{git_identity: identity}) do
    encoded =
      identity
      |> OverallsProtocol.GitIdentity.encode()
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    " lilly.git_identity=" <> encoded
  end

  @spec maybe_git_identity(map(), Spec.t()) :: map()
  defp maybe_git_identity(metadata, %{git_identity: nil}), do: metadata

  defp maybe_git_identity(metadata, %{git_identity: identity}),
    do: Map.put(metadata, "git_identity", OverallsProtocol.GitIdentity.encode(identity))

  @doc "Caller must first confirm the VM cgroup is empty. Unexpected mounts prevent cleanup."
  # @cc [owner:ghuntley,label:assumption;security] jail-cleanup-refuses-unexpected-mounts
  # Callers of cleanup/2 MUST first prove the VM cgroup empty. Cleanup must reject mounts under
  # the jail other than its known boot artifact (kernel, initrd or firmware) and
  # profile-owned drive bindings before removing the jail tree.
  @spec cleanup(Pool.t(), Spec.t(), OverallsProtocol.uuid() | nil) ::
          :ok | {:error, :jail_cleanup_unconfirmed}
  def cleanup(pool, spec, vm_id \\ nil) do
    root = root(pool, spec)

    allowed =
      Enum.map(
        WorkloadBundle.boot_artifacts() ++
          Enum.map(Spec.drives(spec), & &1.name) ++
          ~w(checkpoint-a checkpoint-b restore.memory restore.state),
        &Path.join(root, &1)
      )

    with {:ok, mounts} <- Lilly.Host.MountTable.read(),
         targets =
           mounts
           |> Enum.map(& &1["target"])
           |> Enum.filter(&(&1 == root or String.starts_with?(&1, root <> "/"))),
         true <- Enum.all?(targets, &(&1 in allowed)),
         :ok <- unmount(targets),
         :ok <- Lilly.Host.Privilege.remove_tree(root) do
      :ok
    else
      _ ->
        if vm_id,
          do:
            Lilly.Events.emit("lilly.jail_cleanup_unconfirmed",
              vm_id: vm_id,
              placement_id: spec.id,
              reason: :jail_cleanup_unconfirmed
            )

        {:error, :jail_cleanup_unconfirmed}
    end
  end

  defp mount_boot_artifacts(bundle_directory, pool, spec, bundle) do
    Enum.reduce_while(BundleMetadata.files(bundle), :ok, fn name, :ok ->
      case mount_file(Path.join(bundle_directory, name), root(pool, spec), name, true) do
        :ok -> {:cont, :ok}
        _ -> {:halt, :error}
      end
    end)
  end

  defp write_metadata(_pool, _spec, %{boot_kind: :kernel}, _boot), do: :ok

  defp write_metadata(pool, spec, %{boot_kind: :firmware} = bundle, boot) do
    with :ok <-
           PrivateFiles.write(
             root(pool, spec),
             "metadata.json",
             JSON.encode!(metadata(bundle, spec, boot))
           ),
         do: File.chmod(Path.join(root(pool, spec), "metadata.json"), 0o444)
  end

  @spec prepare_restore(Pool.t(), Spec.t(), Boot.t(), String.t()) ::
          {:ok, WorkloadBundle.t()} | {:error, atom()}
  def prepare_restore(pool, spec, boot, slot) when slot in ["a", "b"] do
    with {:ok, bundle} <- prepare(pool, spec, boot),
         :ok <-
           mount_file(
             Path.join(CheckpointStorage.output(pool, spec.id, slot), "memory"),
             root(pool, spec),
             "restore.memory",
             true
           ),
         :ok <-
           mount_file(
             Path.join(CheckpointStorage.output(pool, spec.id, slot), "state"),
             root(pool, spec),
             "restore.state",
             true
           ),
         do: {:ok, bundle}
  end

  defp mount_checkpoints(pool, spec) do
    Enum.reduce_while(["a", "b"], :ok, fn slot, :ok ->
      target = Path.join(root(pool, spec), "checkpoint-" <> slot)
      {:ok, record} = Lilly.VM.Checkpoint.read(pool, spec.id)
      access = if record["slots"][slot]["state"] == "sealed", do: "ro", else: "rw"

      with :ok <- File.mkdir(target),
           {:ok, _} <-
             Command.run(:mount, [
               "--bind",
               "--",
               CheckpointStorage.output(pool, spec.id, slot),
               target
             ]),
           {:ok, _} <-
             Command.run(:mount, [
               "-o",
               "remount,bind,nosuid,nodev,noexec," <> access,
               "--",
               target
             ]) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :jail_prepare_failed}}
      end
    end)
  end

  defp mount_drives(pool, spec) do
    Enum.reduce_while(Spec.drives(spec), :ok, fn drive, :ok ->
      source = Path.join(Path.dirname(Disk.path(pool, spec)), drive.name)

      case mount_file(source, root(pool, spec), drive.name, false) do
        :ok -> {:cont, :ok}
        _ -> {:halt, :error}
      end
    end)
  end

  defp mount_file(source, root, name, readonly) do
    target = Path.join(root, name)

    with :ok <- File.write(target, "", [:exclusive]),
         {:ok, _} <- Command.run(:mount, ["--bind", "--", source, target]),
         {:ok, _} <-
           Command.run(:mount, [
             "-o",
             "remount,bind,nosuid,nodev,noexec," <> if(readonly, do: "ro", else: "rw"),
             "--",
             target
           ]),
         do: :ok
  end

  defp unmount(targets) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case Command.run(:umount, ["--", target]) do
        {:ok, _} -> {:cont, :ok}
        _ -> {:halt, :error}
      end
    end)
  end
end
