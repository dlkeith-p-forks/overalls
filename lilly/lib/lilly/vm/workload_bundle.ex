defmodule Lilly.VM.WorkloadBundle do
  @moduledoc "Placement-local boot artifacts (kernel and initrd, or firmware) and closed boot metadata."
  import Bitwise
  alias OverallsProtocol.ImageManifest
  alias OverallsProtocol.WorkloadBundle, as: BundleMetadata
  alias Lilly.Host.{Command, Image, PrivateFiles}
  alias Lilly.VM.Spec
  require Lilly.Events

  @marker "boot-bundle.json"
  @copy_timeout 300_000

  @type t :: BundleMetadata.t()

  # @cc [owner:ghuntley,label:storage] workload-bundle-files-by-kind
  # files/1 MUST name exactly the artifact files of the bundle's kind plus the
  # metadata marker; file_sets/0 MUST list every such set and boot_artifacts/0
  # every artifact name any kind may own, so dataset, jail and cleanup code
  # recognise both kernel and firmware bundles without guessing from contents.
  @spec files(t()) :: [String.t()]
  def files(bundle), do: BundleMetadata.files(bundle) ++ [@marker]

  @spec file_sets() :: [[String.t()]]
  def file_sets, do: Enum.map(BundleMetadata.file_sets(), &(&1 ++ [@marker]))

  @spec boot_artifacts() :: [String.t()]
  def boot_artifacts, do: Enum.uniq(List.flatten(BundleMetadata.file_sets()))

  # @cc [owner:ghuntley,label:recovery;security] workload-bundle-published-last
  # materialize/3 MUST consume a freshly digest-verified creation image or an
  # exact sealed image under a native template lease (ADR-0130), publish
  # root-owned read-only boot artifact files durably, and publish the closed
  # metadata marker last. An existing marker MUST match the immutable workload
  # identity and exact artifact shapes; no restart path may recreate it.
  @spec materialize(Path.t(), Image.t(), Spec.t()) :: :ok | {:error, atom()}
  def materialize(directory, image, spec) do
    metadata = metadata(image)

    result =
      case Lilly.Host.Privilege.lstat(Path.join(directory, @marker)) do
        {:error, :enoent} ->
          with true <-
                 image.id == spec.image_id and
                   image.manifest.architecture == :x86_64,
               :ok <- copy_artifacts(directory, image),
               :ok <- PrivateFiles.write(directory, @marker, JSON.encode!(metadata)),
               {:ok, _} <- Command.run(:sync, ["--", directory], @copy_timeout),
               {:ok, _} <- load(directory, spec),
               do: :ok,
               else: (_ -> {:error, :workload_bundle_materialization_failed})

        {:ok, _} ->
          case load(directory, spec) do
            {:ok, bundle} -> if(BundleMetadata.encode(bundle) == metadata, do: :ok, else: error())
            _ -> {:error, :workload_bundle_materialization_failed}
          end

        _ ->
          {:error, :workload_bundle_materialization_failed}
      end

    log_outcome(result, spec.id)
  end

  # @cc [owner:ghuntley,label:observability;security] workload-bundle-outcome-log
  # The diagnostic outcome MUST follow all durable filesystem effects and carry
  # only placement correlation plus a closed reason, never paths or image data.
  defp log_outcome(:ok, placement_id) do
    Lilly.Events.emit("lilly.workload_bundle_materialized", placement_id: placement_id)
    :ok
  end

  defp log_outcome({:error, reason} = error, placement_id) do
    Lilly.Events.emit("lilly.workload_bundle_refused",
      placement_id: placement_id,
      reason: reason
    )

    error
  end

  # @cc [owner:ghuntley,label:security;recovery] workload-bundle-shape-authority
  # load/2 MUST accept only closed metadata matching the workload image and
  # architecture plus exact, root-owned, single-link, read-only artifact files
  # of the bundle's own kind: kernel and initrd for a version-1 bundle, the
  # firmware alone for version-2, version-3 native or version-4 Windows editor bundles. It intentionally verifies no image
  # digest: placement-local ownership and ZFS transfer lineage are the integrity
  # authority after creation.
  @spec load(Path.t(), Spec.t()) :: {:ok, t()} | {:error, :invalid_workload_bundle}
  def load(directory, spec) do
    with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, @marker)),
         true <- byte_size(bytes) <= 16_384,
         {:ok, value} <- JSON.decode(bytes),
         {:ok, bundle} <- BundleMetadata.validate(value),
         true <- bundle.image_id == spec.image_id and bundle.architecture == :x86_64,
         true <-
           Enum.all?(artifact_sizes(bundle), fn {name, size} ->
             artifact?(Path.join(directory, name), size)
           end) do
      {:ok, bundle}
    else
      _ -> {:error, :invalid_workload_bundle}
    end
  end

  @spec artifact_sizes(t()) :: [{String.t(), pos_integer()}]
  defp artifact_sizes(bundle) do
    Enum.flat_map(BundleMetadata.files(bundle), fn name ->
      case bytes_key(name) do
        nil -> []
        key -> if(is_integer(bundle[key]), do: [{name, bundle[key]}], else: [])
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] bundle-retains-git-identity-capability
  # Materialized metadata MUST preserve the verified image's optional Git
  # identity capability so retained starts use their placement-local bundle.
  @spec metadata(Image.t()) :: map()
  defp metadata(image) do
    metadata = metadata_base(image)

    case Map.fetch(image.manifest, :git_identity_version) do
      {:ok, 1} -> Map.put(metadata, "git_identity_version", 1)
      :error -> metadata
    end
  end

  @spec metadata_base(Image.t()) :: map()
  defp metadata_base(%Image{manifest: %{boot_kind: :kernel} = manifest} = image) do
    base = %{
      image_id: image.id,
      architecture: manifest.architecture,
      boot_kind: :kernel,
      guest_agents: Map.get(manifest, :guest_agents, :linux),
      os: Map.get(manifest, :os, :linux),
      boot_args: Map.get(manifest, :boot_args, "")
    }

    base
    |> put_artifact_sizes(image, ImageManifest.boot_artifacts(manifest))
    |> BundleMetadata.encode()
  end

  defp metadata_base(%Image{manifest: %{boot_kind: :firmware, os: os} = manifest} = image)
       when os in [:freebsd, :illumos] do
    {_, firmware} = image.files["firmware"]

    BundleMetadata.encode(%{
      image_id: image.id,
      architecture: manifest.architecture,
      boot_kind: :firmware,
      guest_agents: manifest.guest_agents,
      os: os,
      pci: true,
      firmware_bytes: firmware.size,
      kernel: manifest.kernel
    })
  end

  # @cc [owner:ghuntley,label:security;recovery] bundle-retains-windows-editor-release
  # A verified Windows editor image MUST materialize the version-4 portable
  # bundle with its exact editor tuple and agent set; the generic firmware path
  # MUST NOT discard this release when a placement later starts from storage.
  defp metadata_base(
         %Image{manifest: %{boot_kind: :firmware, guest_agents: :windows_editor_v1} = manifest} =
           image
       ) do
    {_, firmware} = image.files["firmware"]

    BundleMetadata.encode(%{
      image_id: image.id,
      architecture: manifest.architecture,
      boot_kind: :firmware,
      guest_agents: :windows_editor_v1,
      os: :windows,
      pci: true,
      firmware_bytes: firmware.size,
      editor: manifest.editor
    })
  end

  defp metadata_base(%Image{manifest: %{boot_kind: :firmware} = manifest} = image) do
    {_, firmware} = image.files["firmware"]

    BundleMetadata.encode(%{
      image_id: image.id,
      architecture: manifest.architecture,
      boot_kind: :firmware,
      guest_agents: manifest.guest_agents,
      os: Map.get(manifest, :os, :windows),
      pci: true,
      firmware_bytes: firmware.size
    })
  end

  defp copy_artifacts(directory, image) do
    Enum.reduce_while(ImageManifest.boot_artifacts(image.manifest), :ok, fn name, :ok ->
      case copy_artifact(directory, image, name) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp copy_artifact(directory, image, name) do
    destination = Path.join(directory, name)
    temporary = Path.join(directory, ".#{name}.pending")
    {_, expected} = Map.fetch!(image.files, name)

    if artifact?(destination, expected.size) do
      :ok
    else
      arguments = Image.copy_arguments(image, name, temporary)
      copy_missing_artifact(arguments, temporary, destination, directory, expected.size)
    end
  end

  defp copy_missing_artifact(arguments, temporary, destination, directory, expected_size) do
    with :ok <- remove_pending(temporary),
         {:error, :enoent} <- Lilly.Host.Privilege.lstat(destination),
         {:ok, _} <-
           Command.run(
             :image_copy,
             arguments,
             @copy_timeout
           ),
         :ok <- Lilly.Host.Privilege.chmod(temporary, 0o444),
         true <- artifact?(temporary, expected_size),
         {:ok, _} <- Command.run(:sync, ["--", temporary], @copy_timeout),
         {:ok, _} <-
           Command.run(:mv, ["--no-target-directory", "--", temporary, destination]),
         {:ok, _} <- Command.run(:sync, ["--", directory], @copy_timeout),
         do: :ok
  end

  defp artifact?(path, size) do
    case Lilly.Host.Privilege.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1, uid: 0, size: ^size, mode: mode}} ->
        band(mode, 0o777) == 0o444

      _ ->
        false
    end
  end

  defp remove_pending(path) do
    case Lilly.Host.Privilege.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular, links: 1, uid: 0}} -> File.rm(path)
      _ -> {:error, :unsafe_pending_bundle_file}
    end
  end

  defp error, do: {:error, :workload_bundle_materialization_failed}

  defp put_artifact_sizes(bundle, image, names) do
    Enum.reduce(names, bundle, fn name, acc ->
      case {bytes_key(name), image.files[name]} do
        {key, {_, %File.Stat{size: size}}} when is_atom(key) -> Map.put(acc, key, size)
        _ -> acc
      end
    end)
  end

  defp bytes_key("kernel"), do: :kernel_bytes
  defp bytes_key("initrd"), do: :initrd_bytes
  defp bytes_key("firmware"), do: :firmware_bytes
  defp bytes_key(_), do: nil
end
