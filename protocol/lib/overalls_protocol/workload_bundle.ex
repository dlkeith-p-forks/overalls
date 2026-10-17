defmodule OverallsProtocol.WorkloadBundle do
  @moduledoc """
  Closed metadata and capacity bounds for a placement-local boot bundle.

  Version 1 describes a Linux kernel bundle and version 2 a firmware bundle.
  Version 3 carries a native FreeBSD firmware bundle or an illumos firmware
  bundle with an explicit guest-agent set. Existing versions
  remain byte-compatible.
  """

  @kernel_maximum_bytes 536_870_912
  @initrd_maximum_bytes 536_870_912
  @firmware_maximum_bytes 67_108_864
  @metadata_maximum_bytes 16_384
  @storage_bytes 1_073_741_824
  @artifact_maximum_bytes @storage_bytes - @metadata_maximum_bytes

  @type guest_agents :: OverallsProtocol.GuestAgents.t()

  @type kernel_bundle :: %{
          image_id: String.t(),
          architecture: :x86_64,
          boot_kind: :kernel,
          guest_agents: :linux,
          boot_args: String.t(),
          kernel_bytes: pos_integer(),
          initrd_bytes: pos_integer()
        }

  @type native_firmware_bundle :: %{
          image_id: String.t(),
          architecture: :x86_64,
          boot_kind: :firmware,
          os: :illumos,
          guest_agents: :illumos_v1,
          pci: true,
          firmware_bytes: pos_integer(),
          kernel: OverallsProtocol.ImageManifest.kernel_provenance()
        }

  @type native_freebsd_firmware_bundle :: %{
          image_id: String.t(),
          architecture: :x86_64,
          boot_kind: :firmware,
          os: :freebsd,
          guest_agents: :freebsd_v1,
          pci: true,
          firmware_bytes: pos_integer(),
          kernel: OverallsProtocol.ImageManifest.kernel_provenance()
        }

  @type firmware_bundle :: %{
          image_id: String.t(),
          architecture: :x86_64,
          boot_kind: :firmware,
          guest_agents: :none | :windows_v1,
          pci: true,
          firmware_bytes: pos_integer()
        }

  @type t ::
          kernel_bundle()
          | native_firmware_bundle()
          | native_freebsd_firmware_bundle()
          | firmware_bundle()

  @spec storage_bytes() :: pos_integer()
  def storage_bytes, do: @storage_bytes

  # @cc [owner:ghuntley,label:protocol;security] workload-bundle-closed-metadata
  # validate/1 MUST accept only the versioned image identity, architecture and, for
  # version 1, boot arguments with bounded kernel/initrd byte lengths; for version 2,
  # the firmware boot kind with PCI transport, a declared guest agent set (`none` or
  # `windows-v1`) and a bounded firmware byte length; or for version 3, the closed
  # native firmware identity with matching OS, agent set and kernel provenance.
  # Portable metadata MUST NOT contain artifact paths, credentials or host-local authority.
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_workload_bundle}
  def validate(
        %{
          "version" => 1,
          "image_id" => image_id,
          "architecture" => "x86_64",
          "boot_args" => boot_args,
          "kernel_bytes" => kernel_bytes,
          "initrd_bytes" => initrd_bytes
        } = value
      )
      when map_size(value) == 6 do
    if OverallsProtocol.ImageManifest.id?(image_id) and is_binary(boot_args) and
         byte_size(boot_args) in 1..2048 and String.valid?(boot_args) and
         not String.contains?(boot_args, ["\0", "\n", "\r"]) and
         is_integer(kernel_bytes) and kernel_bytes in 1..@kernel_maximum_bytes and
         is_integer(initrd_bytes) and initrd_bytes in 1..@initrd_maximum_bytes and
         kernel_bytes + initrd_bytes <= @artifact_maximum_bytes do
      {:ok,
       %{
         image_id: image_id,
         architecture: :x86_64,
         boot_kind: :kernel,
         guest_agents: :linux,
         boot_args: boot_args,
         kernel_bytes: kernel_bytes,
         initrd_bytes: initrd_bytes
       }}
    else
      {:error, :invalid_workload_bundle}
    end
  end

  def validate(
        %{
          "version" => 2,
          "image_id" => image_id,
          "architecture" => "x86_64",
          "boot" => "firmware",
          "pci" => true,
          "guest_agents" => agents,
          "firmware_bytes" => firmware_bytes
        } = value
      )
      when map_size(value) == 7 and agents in ["none", "windows-v1"] do
    {:ok, agent_set} = OverallsProtocol.GuestAgents.parse(agents)

    if OverallsProtocol.ImageManifest.id?(image_id) and is_integer(firmware_bytes) and
         firmware_bytes in 1..@firmware_maximum_bytes do
      {:ok,
       %{
         image_id: image_id,
         architecture: :x86_64,
         boot_kind: :firmware,
         guest_agents: agent_set,
         pci: true,
         firmware_bytes: firmware_bytes
       }}
    else
      {:error, :invalid_workload_bundle}
    end
  end

  def validate(%{"version" => 3} = value), do: validate_native(value)

  def validate(_), do: {:error, :invalid_workload_bundle}

  # @cc [owner:ghuntley,label:protocol;security] native-workload-bundle-closed
  # Version 3 metadata MUST contain only bounded native firmware fields, with an
  # explicit FreeBSD or illumos image and matching agent set. Native images use
  # the firmware form because Firecracker cannot direct-boot a FreeBSD ELF or
  # load an illumos ZFS disk through its Linux kernel path.
  @spec validate_native(term()) ::
          {:ok, native_freebsd_firmware_bundle() | native_firmware_bundle()}
          | {:error, :invalid_workload_bundle}
  def validate_native(
        %{
          "version" => 3,
          "image_id" => image_id,
          "architecture" => "x86_64",
          "os" => "freebsd",
          "boot" => "firmware",
          "pci" => true,
          "guest_agents" => "freebsd-v1",
          "firmware_bytes" => firmware_bytes,
          "kernel" => kernel
        } = value
      )
      when map_size(value) == 9 do
    if native_keys?(value, [
         "architecture",
         "boot",
         "firmware_bytes",
         "guest_agents",
         "image_id",
         "kernel",
         "os",
         "pci",
         "version"
       ]) and
         OverallsProtocol.ImageManifest.id?(image_id) and
         kernel_provenance?(kernel) and
         is_integer(firmware_bytes) and firmware_bytes in 1..@firmware_maximum_bytes do
      {:ok,
       %{
         image_id: image_id,
         architecture: :x86_64,
         boot_kind: :firmware,
         os: :freebsd,
         guest_agents: :freebsd_v1,
         pci: true,
         firmware_bytes: firmware_bytes,
         kernel: kernel_provenance(kernel)
       }}
    else
      {:error, :invalid_workload_bundle}
    end
  end

  def validate_native(
        %{
          "version" => 3,
          "image_id" => image_id,
          "architecture" => "x86_64",
          "os" => "illumos",
          "boot" => "firmware",
          "pci" => true,
          "guest_agents" => "illumos-v1",
          "firmware_bytes" => firmware_bytes,
          "kernel" => kernel
        } = value
      )
      when map_size(value) == 9 do
    if native_keys?(value, [
         "architecture",
         "boot",
         "firmware_bytes",
         "guest_agents",
         "image_id",
         "kernel",
         "os",
         "pci",
         "version"
       ]) and
         OverallsProtocol.ImageManifest.id?(image_id) and
         kernel_provenance?(kernel) and
         is_integer(firmware_bytes) and firmware_bytes in 1..@firmware_maximum_bytes do
      {:ok,
       %{
         image_id: image_id,
         architecture: :x86_64,
         boot_kind: :firmware,
         os: :illumos,
         guest_agents: :illumos_v1,
         pci: true,
         firmware_bytes: firmware_bytes,
         kernel: kernel_provenance(kernel)
       }}
    else
      {:error, :invalid_workload_bundle}
    end
  end

  def validate_native(_), do: {:error, :invalid_workload_bundle}

  # @cc [owner:ghuntley,label:protocol] workload-bundle-encode-by-kind
  # encode/1 MUST emit exactly the six version-1 keys for a Linux kernel bundle,
  # the seven version-2 keys for a Windows firmware bundle, or the closed version-3
  # native shape, so an on-disk marker compares equal to its validated bundle.
  @spec encode(t()) :: map()
  def encode(%{boot_kind: :kernel} = bundle) do
    %{
      "version" => 1,
      "image_id" => bundle.image_id,
      "architecture" => Atom.to_string(bundle.architecture),
      "boot_args" => bundle.boot_args,
      "kernel_bytes" => bundle.kernel_bytes,
      "initrd_bytes" => bundle.initrd_bytes
    }
  end

  def encode(%{boot_kind: :firmware, os: os} = bundle) when os in [:freebsd, :illumos] do
    %{
      "version" => 3,
      "image_id" => bundle.image_id,
      "architecture" => "x86_64",
      "os" => Atom.to_string(os),
      "boot" => "firmware",
      "pci" => true,
      "guest_agents" => OverallsProtocol.GuestAgents.wire(bundle.guest_agents),
      "firmware_bytes" => bundle.firmware_bytes,
      "kernel" => encode_kernel(bundle.kernel)
    }
  end

  def encode(%{boot_kind: :firmware} = bundle) do
    %{
      "version" => 2,
      "image_id" => bundle.image_id,
      "architecture" => Atom.to_string(bundle.architecture),
      "boot" => "firmware",
      "pci" => true,
      "guest_agents" => OverallsProtocol.GuestAgents.wire(bundle.guest_agents),
      "firmware_bytes" => bundle.firmware_bytes
    }
  end

  # @cc [owner:ghuntley,label:protocol] workload-bundle-files-by-kind
  # files/1 is the only authority for a bundle's artifact file names: a kernel bundle
  # owns exactly `kernel` and `initrd`, a firmware bundle exactly `firmware`. Callers
  # add the metadata marker themselves.
  @spec files(t()) :: [String.t()]
  def files(%{boot_kind: :kernel}), do: ["kernel", "initrd"]
  def files(%{boot_kind: :firmware, os: os}) when os in [:freebsd, :illumos], do: ["firmware"]
  def files(%{boot_kind: :firmware}), do: ["firmware"]

  @spec file_sets() :: [[String.t()]]
  def file_sets, do: [["kernel", "initrd"], ["kernel"], ["firmware"]]

  defp native_keys?(value, expected), do: Map.keys(value) |> Enum.sort() == Enum.sort(expected)

  defp kernel_provenance?(value),
    do: match?({:ok, _}, OverallsProtocol.ImageManifest.kernel_provenance(value))

  defp kernel_provenance(value) do
    {:ok, normalized} = OverallsProtocol.ImageManifest.kernel_provenance(value)
    normalized
  end

  defp encode_kernel(value) do
    %{
      "bytes" => value.bytes,
      "sha256" => value.sha256,
      "source_revision" => value.source_revision,
      "patch_hash" => value.patch_hash,
      "configuration_hash" => value.configuration_hash,
      "compiler" => value.compiler
    }
  end
end
