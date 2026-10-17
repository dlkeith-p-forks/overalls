defmodule Lilly.Host.Image do
  @moduledoc "Locally staged, read-only image artifacts. Verify bytes before advertising availability."
  import Bitwise
  alias OverallsProtocol.ImageManifest
  alias Lilly.Host.Command
  @enforce_keys [:id, :path, :manifest, :files]
  defstruct [
    :id,
    :path,
    :manifest,
    :files,
    :source_lease,
    :template_record_id,
    :template_incarnation,
    verified: false
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          path: Path.t(),
          manifest: ImageManifest.t(),
          files: %{String.t() => {Path.t(), File.Stat.t()}},
          source_lease: Path.t() | nil,
          template_record_id: String.t() | nil,
          template_incarnation: String.t() | nil,
          verified: boolean()
        }

  # @cc [owner:ghuntley,label:recovery] image-copy-lease-propagation
  # Every template artifact copy MUST pass the exact native lease to the Rust
  # child. The caller retains its independent placement mutation owner; neither
  # a parent-only source lease nor a template-only child lock protects both sides.
  @spec copy_arguments(t(), String.t(), Path.t()) :: [String.t()]
  def copy_arguments(image, name, destination) do
    {source, stat} = Map.fetch!(image.files, name)
    arguments = ["auto", source, destination, Integer.to_string(stat.size)]
    if image.source_lease, do: arguments ++ [image.source_lease], else: arguments
  end

  # @cc [owner:ghuntley,label:security] image-bytes-verified-before-use
  # load/1 MUST validate the manifest and verify each artifact size and SHA-256 digest against
  # read-only files with trusted ancestry before returning a usable image. A mismatch or unsafe
  # artifact rejects the whole image.
  @spec load(Path.t()) :: {:ok, t()} | {:error, :invalid_local_image}
  def load(path), do: inspect_image(path, :hash)

  # @cc [owner:ghuntley,label:security;recovery] image-digest-cache-exact-identity
  # load_cached/2 MUST return a verified image without rehashing only when the
  # private cache records this exact path and manifest ID with native file
  # identities (device, inode, size, nanosecond mtime and ctime) equal to the
  # ones read now, after every stage/1 check passed. Otherwise it MUST run
  # load/1, and it MAY record the result only when the identities read before
  # and after hashing are equal. An unreadable, foreign-owned, group- or
  # world-accessible or malformed cache MUST be ignored, never trusted.
  @spec load_cached(Path.t(), Path.t()) :: {:ok, t()} | {:error, :invalid_local_image}
  def load_cached(path, cache) do
    with {:ok, staged} <- stage(path),
         {:ok, before} <- identities(staged) do
      entries = read_cache(cache)

      if entries[path] == %{"id" => staged.id, "identities" => before} do
        {:ok, %{staged | verified: true}}
      else
        with {:ok, image} <- load(path) do
          with {:ok, ^before} <- identities(image),
               true <- image.id == staged.id do
            write_cache(
              cache,
              Map.put(entries, path, %{"id" => image.id, "identities" => before})
            )
          end

          {:ok, image}
        end
      end
    else
      _ -> {:error, :invalid_local_image}
    end
  end

  defp read_cache(cache) do
    with {:ok, %File.Stat{type: :regular, mode: mode, uid: owner}} <- File.lstat(cache),
         true <- band(mode, 0o077) == 0 and owner == uid(),
         {:ok, body} <- File.read(cache),
         {:ok, %{} = entries} <- JSON.decode(body),
         true <-
           Enum.all?(entries, fn
             {key, %{"id" => id, "identities" => %{} = identities}}
             when is_binary(key) and is_binary(id) ->
               Enum.all?(identities, fn {name, values} ->
                 is_binary(name) and is_list(values) and
                   Enum.all?(values, &(is_integer(&1) and &1 >= 0))
               end)

             _ ->
               false
           end) do
      entries
    else
      _ -> %{}
    end
  end

  # Best effort: a failed write only means the next boot hashes again.
  defp write_cache(cache, entries) do
    pending = cache <> ".pending"

    with :ok <- File.mkdir_p(Path.dirname(cache)),
         :ok <- File.chmod(Path.dirname(cache), 0o700),
         _ <- File.rm(pending),
         :ok <- File.write(pending, JSON.encode!(entries), [:exclusive]),
         :ok <- File.chmod(pending, 0o600),
         :ok <- File.rename(pending, cache) do
      :ok
    else
      _ ->
        File.rm(pending)
        :ok
    end
  end

  @doc "Validate manifest, ancestry, modes and sizes without hashing artifact bytes."
  # @cc [owner:ghuntley,label:security;recovery] staged-image-never-advertised
  # stage/1 MUST apply every load/1 check except artifact digests and return
  # verified: false. A staged image identifies a configured path for startup and
  # launch lookup only; it MUST NOT be advertised, and launch MUST call load/1.
  @spec stage(Path.t()) :: {:ok, t()} | {:error, :invalid_local_image}
  def stage(path), do: inspect_image(path, :stage)

  # @cc [owner:ghuntley,label:security] sealed-image-independent-authority
  # sealed/2 MUST validate the manifest and exact recorded file identities without
  # rehashing. Callers MUST hold a template reader lease and independently verify
  # its owned dataset GUID and readonly seal before and after this check. This
  # function alone MUST NOT authorize copying or launch.
  @spec sealed(Path.t(), map()) :: {:ok, t()} | {:error, :invalid_local_image}
  def sealed(path, expected) do
    with {:ok, image} <- inspect_image(path, :identity),
         {:ok, ^expected} <- identities(image),
         true <-
           Enum.all?(image.files, fn {_, {_, stat}} -> stat.uid == 0 and stat.links == 1 end),
         do: {:ok, image},
         else: (_ -> {:error, :invalid_local_image})
  end

  # @cc [owner:ghuntley,label:security] template-file-identity-precision
  # Persisted identities MUST include nanosecond mtime and ctime from the native
  # file descriptor, not File.Stat's second-resolution timestamps. Invalid or
  # unreadable native identities MUST fail, never reuse a cached identity.
  @spec identities(t()) ::
          {:ok, %{String.t() => [non_neg_integer()]}} | {:error, :invalid_local_image}
  def identities(image) do
    Enum.reduce_while(image.files, {:ok, %{}}, fn {name, {path, _}}, {:ok, identities} ->
      with {:ok, bytes} <- Command.run(:image_identity, [path]),
           {:ok, values} when is_list(values) and length(values) == 11 <- JSON.decode(bytes),
           true <- Enum.all?(values, &(is_integer(&1) and &1 >= 0)) do
        {:cont, {:ok, Map.put(identities, name, values)}}
      else
        _ -> {:halt, {:error, :invalid_local_image}}
      end
    end)
  end

  defp inspect_image(path, verification) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, {manifest_path, stat}} <- resolve(Path.join(path, "manifest.json")),
         true <- stat.size <= 16_384,
         {:ok, body} <- File.read(manifest_path),
         {:ok, value} <- JSON.decode(body),
         {:ok, manifest} <- ImageManifest.validate(value),
         {:ok, files} <- artifacts(path, manifest, verification),
         image = %__MODULE__{
           id: manifest.id,
           path: path,
           manifest: manifest,
           files: Map.put(files, "manifest.json", {manifest_path, stat}),
           verified: verification == :hash
         },
         true <- unchanged?(image) do
      {:ok, image}
    else
      _ -> {:error, :invalid_local_image}
    end
  end

  defp inspect_image(_, _), do: {:error, :invalid_local_image}

  @doc "Cheap availability check. The VM driver must call load again before copying/launching."
  # @cc [owner:ghuntley,label:assumption;security] availability-does-not-authorize-launch
  # unchanged?/1 is only a cached identity check for availability reporting. Callers that copy
  # boot artifacts or initialize a disk MUST call load/1 again, or hold the
  # independently validated sealed template lease under ADR-0130, and match the
  # admitted image ID before using bytes. unchanged?/1 alone is never authority.
  @spec unchanged?(t()) :: boolean()
  def unchanged?(image) do
    Enum.all?(image.files, fn {name, original} ->
      resolve(Path.join(image.path, name)) == {:ok, original}
    end)
  end

  # @cc [owner:ghuntley,label:security] only-digest-verified-images-advertised
  # available_ids/1 MUST exclude staged (unhashed) images even when their file
  # identity is unchanged; availability requires a completed load/1 digest proof.
  @spec available_ids([t()]) :: [String.t()]
  def available_ids(images),
    do:
      images
      |> Enum.filter(&(&1.verified == true and unchanged?(&1)))
      |> Enum.map(& &1.id)
      |> Enum.sort()

  @doc "Image-side file name of the root disk artifact (`rootfs.ext4` or `disk.raw`)."
  @spec root_artifact(t()) :: String.t()
  def root_artifact(%__MODULE__{manifest: manifest}), do: ImageManifest.root_artifact(manifest)

  @doc "Every file this image's directory holds, including the manifest."
  @spec file_names(t()) :: [String.t()]
  def file_names(%__MODULE__{manifest: manifest}), do: ImageManifest.file_names(manifest)

  @doc "Every closed image directory file set a template may hold."
  @spec file_sets() :: [[String.t()]]
  def file_sets, do: ImageManifest.file_sets()

  # @cc [owner:ghuntley,label:security] image-artifacts-follow-manifest-kind
  # artifacts/3 MUST verify exactly the files the validated manifest's boot kind
  # names (kernel, optional initrd and the declared root artifact, or firmware and
  # disk.raw) and nothing
  # else; the file list comes from the protocol, never from directory contents.
  defp artifacts(path, manifest, verification) do
    Enum.reduce_while(
      ImageManifest.artifact_files(manifest),
      {:ok, %{}},
      fn {file, descriptor}, {:ok, files} ->
        with {:ok, {resolved, stat}} <- resolve(Path.join(path, file)),
             true <- stat.size == descriptor["bytes"],
             :ok <- verify_digest(resolved, stat.size, descriptor["sha256"], verification) do
          {:cont, {:ok, Map.put(files, file, {resolved, stat})}}
        else
          _ -> {:halt, :error}
        end
      end
    )
  end

  defp verify_digest(_, _, _, verification) when verification in [:identity, :stage], do: :ok

  defp verify_digest(path, size, expected, :hash) do
    case hash_file(path, size) do
      {:ok, ^expected} -> :ok
      _ -> :error
    end
  end

  defp resolve(path) do
    with false <- String.contains?(path, ["\n", "\r", "\0"]),
         :ok <- safe_ancestors(Path.dirname(path)),
         {:ok, output} <- Command.run(:realpath, ["-e", "--", path]),
         resolved = String.trim_trailing(output, "\n"),
         true <- Path.type(resolved) == :absolute,
         :ok <- safe_ancestors(Path.dirname(resolved)),
         {:ok, %File.Stat{type: :regular, mode: mode, uid: uid} = stat} <- File.lstat(resolved),
         true <- band(mode, 0o222) == 0 and uid in [0, uid()] do
      # Reading may update atime; it is not part of artifact identity.
      {:ok, {resolved, %{stat | atime: {{1970, 1, 1}, {0, 0, 0}}}}}
    else
      _ -> :error
    end
  end

  defp safe_ancestors("/"), do: :ok

  defp safe_ancestors(path) do
    with {:ok, %File.Stat{type: :directory, mode: mode, uid: owner}} <- File.lstat(path),
         true <- owner in [0, uid()],
         true <- band(mode, 0o022) == 0 or band(mode, 0o1000) != 0,
         do: safe_ancestors(Path.dirname(path))
  end

  defp uid do
    {:ok, stat} = File.stat("/proc/self")
    stat.uid
  end

  defp hash_file(path, size) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        hash_chunks(file, size, :crypto.hash_init(:sha256))
      after
        File.close(file)
      end
    end
  end

  defp hash_chunks(file, 0, context) do
    case IO.binread(file, 1) do
      :eof -> {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      _ -> :error
    end
  end

  defp hash_chunks(file, remaining, context) do
    case IO.binread(file, min(remaining, 65_536)) do
      bytes when is_binary(bytes) and byte_size(bytes) > 0 ->
        hash_chunks(file, remaining - byte_size(bytes), :crypto.hash_update(context, bytes))

      _ ->
        :error
    end
  end
end
