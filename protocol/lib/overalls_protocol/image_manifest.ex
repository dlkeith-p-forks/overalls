defmodule OverallsProtocol.ImageManifest do
  @moduledoc """
  Immutable image identity.

  Version 4 describes kernel-booted Linux images (kernel, initrd, ext4 root,
  boot arguments) with explicit workspace-source and editor capabilities.
  Version 5 describes firmware-booted images (a PVH firmware and a raw GPT
  root disk) that declare no guest agents or the Windows v1 agent set.
  Version 6 adds native FreeBSD and
  illumos firmware disk images. Both derive the same content-addressed
  `sha256:` identity from an ordered identity array.
  """
  @type workspace_source_version :: 2 | nil
  @type boot_kind :: :kernel | :firmware
  @type os :: :linux | :windows | :freebsd | :illumos
  @type root_format :: :ext4 | :raw_gpt
  @type guest_agents :: OverallsProtocol.GuestAgents.t()

  @type kernel_image :: %{
          optional(:editor) => OverallsProtocol.EditorRelease.t(),
          id: String.t(),
          architecture: :x86_64,
          boot_kind: :kernel,
          pci: false,
          root_format: :ext4,
          guest_agents: :linux,
          boot_args: String.t(),
          minimum_memory_bytes: pos_integer(),
          minimum_disk_bytes: pos_integer(),
          workspace_source_version: workspace_source_version(),
          manifest: map()
        }

  @type firmware_image :: %{
          id: String.t(),
          architecture: :x86_64,
          boot_kind: :firmware,
          pci: true,
          root_format: :raw_gpt,
          guest_agents: :none | :windows_v1,
          minimum_memory_bytes: pos_integer(),
          minimum_disk_bytes: pos_integer(),
          workspace_source_version: workspace_source_version(),
          manifest: map()
        }

  @type kernel_provenance :: %{
          bytes: pos_integer(),
          sha256: String.t(),
          source_revision: String.t(),
          patch_hash: String.t(),
          configuration_hash: String.t(),
          compiler: String.t()
        }

  @type native_image :: %{
          id: String.t(),
          architecture: :x86_64,
          os: :freebsd | :illumos,
          boot_kind: :firmware,
          pci: true,
          root_format: :raw_gpt,
          guest_agents: :freebsd_v1 | :illumos_v1,
          minimum_memory_bytes: pos_integer(),
          minimum_disk_bytes: pos_integer(),
          workspace_source_version: workspace_source_version(),
          kernel: kernel_provenance(),
          manifest: map()
        }

  @type t :: kernel_image() | firmware_image() | native_image()

  @boot_artifact_maximum_bytes 8_589_934_592
  @firmware_maximum_bytes 67_108_864
  @root_maximum_bytes 137_438_953_472

  # @cc [owner:ghuntley,label:protocol] image-content-addressed-identity
  # validate/1 MUST derive the image ID from the versioned architecture, boot requirements
  # (kind, PCI transport and boot arguments where present), minimum resource sizes, declared
  # capabilities and every artifact size/digest using the ordered identity encoding. Reordering
  # JSON fields must not change the ID; changing a boot requirement or artifact descriptor must
  # change it. Version-4, version-5 and version-6 manifests never share an ID.

  # @cc [owner:ghuntley,label:protocol] image-rootfs-admission-bound
  # validate/1 MUST accept root artifacts (ext4 or raw GPT) through 128 GiB
  # inclusive, reject larger ones, and require the declared minimum disk to fit the root bytes.

  # @cc [owner:ghuntley,label:protocol] image-boot-artifact-bounds
  # validate/1 MUST accept kernel and initrd artifacts through 8 GiB each and firmware
  # artifacts through 64 MiB, inclusive, and reject a descriptor that exceeds its bound.

  # @cc [owner:ghuntley,label:protocol;security] image-firmware-manifest-closed
  # A version-5 manifest MUST be accepted only with exactly the eight documented keys:
  # `boot.kind` `firmware` with `pci` true and one firmware descriptor, `root.format`
  # `raw-gpt` with one root descriptor, `guest_agents` `none` or `windows-v1`, and
  # `workspace_source_version` null, or 2 only together with `windows-v1`. Editor
  # descriptors, display names, boot arguments or kernel artifacts in a version-5
  # manifest MUST be refused. The agent set is part of the identity.
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_image_manifest}
  def validate(
        %{
          "version" => 4,
          "architecture" => "x86_64",
          "boot_args" => boot,
          "minimum_memory_bytes" => memory,
          "minimum_disk_bytes" => disk,
          "kernel" => kernel,
          "initrd" => initrd,
          "rootfs" => rootfs,
          "workspace_source_version" => workspace_source_version
        } = manifest
      )
      when map_size(manifest) in [9, 10] do
    with true <- workspace_source_version in [nil, 2],
         {:ok, editor} <- editor_descriptor(manifest),
         true <- is_binary(boot) and byte_size(boot) in 1..2048,
         true <- String.valid?(boot) and not String.contains?(boot, ["\0", "\n", "\r"]),
         true <- minima?(memory, disk),
         true <-
           artifact?(kernel, @boot_artifact_maximum_bytes) and
             artifact?(initrd, @boot_artifact_maximum_bytes),
         true <- artifact?(rootfs, @root_maximum_bytes) and disk >= rootfs["bytes"] do
      # Ordered JSON arrays avoid depending on map order, source whitespace or
      # a particular JSON object's canonicalization rules across languages.
      identity = [
        "lilly-image-v4",
        "x86_64",
        boot,
        memory,
        disk,
        workspace_source_version,
        if(editor, do: [editor.protocol, editor.commit, editor.release]),
        [kernel["bytes"], kernel["sha256"]],
        [initrd["bytes"], initrd["sha256"]],
        [rootfs["bytes"], rootfs["sha256"]]
      ]

      image = %{
        id: identity_id(identity),
        architecture: :x86_64,
        boot_kind: :kernel,
        pci: false,
        root_format: :ext4,
        guest_agents: :linux,
        boot_args: boot,
        minimum_memory_bytes: memory,
        minimum_disk_bytes: disk,
        workspace_source_version: workspace_source_version,
        manifest: manifest
      }

      {:ok, if(editor, do: Map.put(image, :editor, editor), else: image)}
    else
      _ -> {:error, :invalid_image_manifest}
    end
  end

  def validate(
        %{
          "version" => 5,
          "architecture" => "x86_64",
          "boot" => %{"kind" => "firmware", "pci" => true, "firmware" => firmware} = boot,
          "root" => %{"format" => "raw-gpt"} = root,
          "guest_agents" => agents,
          "minimum_memory_bytes" => memory,
          "minimum_disk_bytes" => disk,
          "workspace_source_version" => workspace_source_version
        } = manifest
      )
      when map_size(manifest) == 8 and map_size(boot) == 3 and map_size(root) == 3 and
             agents in ["none", "windows-v1"] do
    root_artifact = Map.delete(root, "format")
    {:ok, agent_set} = OverallsProtocol.GuestAgents.parse(agents)

    with true <- workspace_source_version in [nil, 2],
         true <- workspace_source_version == nil or agent_set == :windows_v1,
         true <- minima?(memory, disk),
         true <- artifact?(firmware, @firmware_maximum_bytes),
         true <- artifact?(root_artifact, @root_maximum_bytes) and disk >= root["bytes"] do
      identity = [
        "lilly-image-v5",
        "x86_64",
        "firmware",
        true,
        "raw-gpt",
        agents,
        memory,
        disk,
        workspace_source_version,
        [firmware["bytes"], firmware["sha256"]],
        [root["bytes"], root["sha256"]]
      ]

      {:ok,
       %{
         id: identity_id(identity),
         architecture: :x86_64,
         boot_kind: :firmware,
         pci: true,
         root_format: :raw_gpt,
         guest_agents: agent_set,
         minimum_memory_bytes: memory,
         minimum_disk_bytes: disk,
         workspace_source_version: workspace_source_version,
         manifest: manifest
       }}
    else
      _ -> {:error, :invalid_image_manifest}
    end
  end

  def validate(%{"version" => 6} = manifest), do: validate_native(manifest)

  def validate(_), do: {:error, :invalid_image_manifest}

  # @cc [owner:ghuntley,label:protocol;security] image-native-manifest-closed
  # Version 6 admits only the explicit FreeBSD or illumos native image shapes;
  # each OS is bound to its agent set, boot transport and root format. Unknown
  # keys, source versions on agentless images, cross-OS substitutions and native
  # manifests without complete kernel provenance refuse.
  @spec validate_native(term()) :: {:ok, native_image()} | {:error, :invalid_image_manifest}
  def validate_native(%{"version" => 6, "os" => "freebsd"} = manifest),
    do: validate_freebsd(manifest)

  def validate_native(%{"version" => 6, "os" => "illumos"} = manifest),
    do: validate_illumos(manifest)

  def validate_native(_), do: {:error, :invalid_image_manifest}

  @doc "Validate and normalize the immutable native kernel provenance descriptor."
  @spec kernel_provenance(term()) ::
          {:ok, kernel_provenance()} | {:error, :invalid_kernel_provenance}
  def kernel_provenance(value) do
    if kernel_provenance?(value),
      do: {:ok, kernel_provenance_map(value)},
      else: {:error, :invalid_kernel_provenance}
  end

  @spec encode(t()) :: map()
  def encode(%{manifest: manifest}), do: manifest

  # @cc [owner:ghuntley,label:protocol] image-artifact-files-by-boot-kind
  # artifact_files/1, boot_artifacts/1 and root_artifact/1 are the only authority for
  # the image directory file names of a validated manifest: kernel images are exactly
  # `kernel`, optional `initrd` and the OS root artifact; firmware images are exactly `firmware` and
  # `disk.raw`. Every descriptor returned MUST be the manifest's own bytes/sha256 pair.
  @spec artifact_files(t()) :: [{String.t(), %{String.t() => term()}}]
  def artifact_files(%{boot_kind: :kernel, manifest: manifest}) do
    root = "rootfs.ext4"
    files = [{"kernel", manifest["kernel"]}]

    files =
      if Map.has_key?(manifest, "initrd"),
        do: files ++ [{"initrd", manifest["initrd"]}],
        else: files

    files ++ [{root, manifest["rootfs"]}]
  end

  def artifact_files(%{boot_kind: :firmware, manifest: manifest}) do
    [
      {"firmware", manifest["boot"]["firmware"]},
      {"disk.raw", Map.delete(manifest["root"], "format")}
    ]
  end

  @spec boot_artifacts(t()) :: [String.t()]
  def boot_artifacts(%{boot_kind: :kernel, manifest: manifest}) do
    if Map.has_key?(manifest, "initrd"), do: ["kernel", "initrd"], else: ["kernel"]
  end

  def boot_artifacts(%{boot_kind: :firmware}), do: ["firmware"]

  @doc "Every file an image directory of the given validated manifest contains."
  @spec file_names(t()) :: [String.t()]
  def file_names(image), do: ["manifest.json" | Enum.map(artifact_files(image), &elem(&1, 0))]

  @doc "The closed image directory file sets of every supported manifest version."
  @spec file_sets() :: [[String.t()]]
  def file_sets do
    [
      ["manifest.json", "kernel", "initrd", "rootfs.ext4"],
      ["manifest.json", "firmware", "disk.raw"]
    ]
  end

  @spec root_artifact(t()) :: String.t()
  def root_artifact(%{boot_kind: :kernel}), do: "rootfs.ext4"

  def root_artifact(%{boot_kind: :firmware}), do: "disk.raw"

  @spec boot_kind(t()) :: boot_kind()
  def boot_kind(%{boot_kind: kind}) when kind in [:kernel, :firmware], do: kind

  # @cc [owner:ghuntley,label:security;protocol] image-guest-agents-no-inference
  # Guest agent capability MUST come only from a validated manifest: version 4 images
  # carry Linux, version 5 declares `none`/`windows-v1`, and version 6 declares
  # the matching native OS agent set.
  # Installed guest software, package presence or caller hints MUST NOT grant or
  # remove agent capability; what a set can do is OverallsProtocol.GuestAgents'
  # table, qualified by exact reviewed native image identity for capabilities/2.
  @spec guest_agents(t()) :: guest_agents()
  def guest_agents(%{guest_agents: agents})
      when agents in [:linux, :none, :windows_v1, :freebsd_v1, :illumos_v1],
      do: agents

  # @cc [owner:ghuntley,label:security;protocol] image-editor-capability-no-inference
  # Editor capability MUST come only from a validated v4 content-bound descriptor.
  # A non-editor image, package presence or caller hint MUST NOT grant capability.
  @spec editor(term()) ::
          {:ok, OverallsProtocol.EditorRelease.t()} | {:error, :editor_unavailable}
  def editor(manifest) do
    case validate(manifest) do
      {:ok, %{editor: editor}} -> {:ok, editor}
      _ -> {:error, :editor_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security;protocol] image-workspace-capability-no-inference
  # Source delivery MUST be available only when a current validated manifest
  # explicitly declares source protocol 2; installed binaries never imply it.
  @spec workspace_source?(term()) :: boolean()
  def workspace_source?(manifest) do
    match?({:ok, %{workspace_source_version: 2}}, validate(manifest))
  end

  @spec id?(term()) :: boolean()
  def id?("sha256:" <> digest), do: digest?(digest)
  def id?(_), do: false

  # @cc [owner:ghuntley,label:protocol] advertised-images-bounded-distinct
  # ids?/1 MUST reject more than 128 image IDs, duplicates and IDs that are not canonical
  # lowercase sha256 digests.
  @spec ids?(term()) :: boolean()
  def ids?(ids) when is_list(ids) and length(ids) <= 128,
    do: Enum.all?(ids, &id?/1) and Enum.uniq(ids) == ids

  def ids?(_), do: false

  @spec identity_id([term()]) :: String.t()
  defp identity_id(identity) do
    digest = :crypto.hash(:sha256, JSON.encode!(identity)) |> Base.encode16(case: :lower)
    "sha256:" <> digest
  end

  # FreeBSD's published VM image is a complete GPT disk (EFI system partition,
  # bootfs and UFS root). Firecracker's direct kernel loader only accepts Linux
  # boot-protocol/PVH images, so FreeBSD uses the CloudHv PVH firmware path and
  # retains the full disk for UEFI discovery.
  defp validate_freebsd(
         %{
           "version" => 6,
           "os" => "freebsd",
           "architecture" => "x86_64",
           "boot" => %{"kind" => "firmware", "pci" => true, "firmware" => firmware} = boot,
           "kernel" => kernel,
           "root" => %{"format" => "raw-gpt"} = root,
           "guest_agents" => "freebsd-v1",
           "minimum_memory_bytes" => memory,
           "minimum_disk_bytes" => disk,
           "workspace_source_version" => source
         } = manifest
       )
       when map_size(manifest) == 10 and map_size(boot) == 3 and map_size(root) == 3 do
    root_artifact = Map.delete(root, "format")

    with true <- source in [nil, 2],
         true <- minima?(memory, disk),
         true <- kernel_provenance?(kernel),
         true <- artifact?(firmware, @firmware_maximum_bytes),
         true <- artifact?(root_artifact, @root_maximum_bytes) and disk >= root_artifact["bytes"] do
      identity = [
        "lilly-image-v6",
        "freebsd",
        "x86_64",
        "firmware",
        true,
        "raw-gpt",
        memory,
        disk,
        source,
        kernel_identity(kernel),
        [firmware["bytes"], firmware["sha256"]],
        [root_artifact["bytes"], root_artifact["sha256"]]
      ]

      {:ok,
       %{
         id: identity_id(identity),
         architecture: :x86_64,
         os: :freebsd,
         boot_kind: :firmware,
         pci: true,
         root_format: :raw_gpt,
         guest_agents: :freebsd_v1,
         minimum_memory_bytes: memory,
         minimum_disk_bytes: disk,
         workspace_source_version: source,
         kernel: kernel_provenance_map(kernel),
         manifest: manifest
       }}
    else
      _ -> {:error, :invalid_image_manifest}
    end
  end

  defp validate_freebsd(_), do: {:error, :invalid_image_manifest}

  defp validate_illumos(
         %{
           "version" => 6,
           "os" => "illumos",
           "architecture" => "x86_64",
           "boot" => %{"kind" => "firmware", "pci" => true, "firmware" => firmware} = boot,
           "kernel" => kernel,
           "root" => %{"format" => "raw-gpt"} = root,
           "guest_agents" => "illumos-v1",
           "minimum_memory_bytes" => memory,
           "minimum_disk_bytes" => disk,
           "workspace_source_version" => source
         } = manifest
       )
       when map_size(manifest) == 10 and map_size(boot) == 3 and map_size(root) == 3 do
    root_artifact = Map.delete(root, "format")

    with true <- source in [nil, 2],
         true <- minima?(memory, disk),
         true <- kernel_provenance?(kernel),
         true <- artifact?(firmware, @firmware_maximum_bytes),
         true <- artifact?(root_artifact, @root_maximum_bytes) and disk >= root_artifact["bytes"] do
      identity = [
        "lilly-image-v6",
        "illumos",
        "x86_64",
        "firmware",
        true,
        "raw-gpt",
        memory,
        disk,
        source,
        kernel_identity(kernel),
        [firmware["bytes"], firmware["sha256"]],
        [root_artifact["bytes"], root_artifact["sha256"]]
      ]

      {:ok,
       %{
         id: identity_id(identity),
         architecture: :x86_64,
         os: :illumos,
         boot_kind: :firmware,
         pci: true,
         root_format: :raw_gpt,
         guest_agents: :illumos_v1,
         minimum_memory_bytes: memory,
         minimum_disk_bytes: disk,
         workspace_source_version: source,
         kernel: kernel_provenance_map(kernel),
         manifest: manifest
       }}
    else
      _ -> {:error, :invalid_image_manifest}
    end
  end

  defp validate_illumos(_), do: {:error, :invalid_image_manifest}

  @spec minima?(term(), term()) :: boolean()
  defp minima?(memory, disk) do
    is_integer(memory) and memory in 536_870_912..274_877_906_944 and
      is_integer(disk) and disk in 1..17_592_186_044_416
  end

  @spec editor_descriptor(map()) ::
          {:ok, OverallsProtocol.EditorRelease.t() | nil} | {:error, term()}
  defp editor_descriptor(%{"editor" => descriptor} = manifest) when map_size(manifest) == 10,
    do: OverallsProtocol.EditorRelease.decode(descriptor)

  defp editor_descriptor(manifest) when map_size(manifest) == 9, do: {:ok, nil}
  defp editor_descriptor(_), do: {:error, :invalid_image_manifest}

  defp artifact?(%{"bytes" => size, "sha256" => digest} = value, maximum)
       when map_size(value) == 2,
       do: is_integer(size) and size > 0 and size <= maximum and digest?(digest)

  defp artifact?(_, _), do: false

  defp kernel_provenance?(
         %{
           "bytes" => bytes,
           "sha256" => sha256,
           "source_revision" => source_revision,
           "patch_hash" => patch_hash,
           "configuration_hash" => configuration_hash,
           "compiler" => compiler
         } = value
       )
       when map_size(value) == 6 do
    artifact?(%{"bytes" => bytes, "sha256" => sha256}, @boot_artifact_maximum_bytes) and
      git_revision?(source_revision) and digest?(patch_hash) and digest?(configuration_hash) and
      compiler_identity?(compiler)
  end

  defp kernel_provenance?(_), do: false

  defp kernel_provenance_map(value) do
    %{
      bytes: value["bytes"],
      sha256: value["sha256"],
      source_revision: value["source_revision"],
      patch_hash: value["patch_hash"],
      configuration_hash: value["configuration_hash"],
      compiler: value["compiler"]
    }
  end

  defp kernel_identity(value) do
    [
      value["bytes"],
      value["sha256"],
      value["source_revision"],
      value["patch_hash"],
      value["configuration_hash"],
      value["compiler"]
    ]
  end

  defp git_revision?(value) when is_binary(value) and byte_size(value) in [40, 64],
    do: Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp git_revision?(_), do: false

  defp compiler_identity?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: String.valid?(value) and not String.contains?(value, [<<0>>, "\n", "\r"])

  defp compiler_identity?(_), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp digest?(_), do: false
end
