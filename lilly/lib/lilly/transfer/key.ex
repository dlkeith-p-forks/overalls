defmodule Lilly.Transfer.Key do
  @moduledoc "Destination-local Ed25519 credentials bound permanently to one relocation and placement."
  require Lilly.Events
  alias Lilly.Host.{Command, Lock, PrivateFiles}
  @key "id_ed25519"

  # @cc [owner:ghuntley,label:security;recovery] transfer-key-never-replaced-after-publication
  # ensure/4 MUST return only a public key after syncing its private key and ready
  # journal under the relocation lock. Ready keys cannot be regenerated, even if
  # lost or corrupt. Pending generation may be repaired because no public key has
  # been returned. Host/placement rebinding and retired-key resurrection MUST fail.
  # The root is trusted local configuration, never a path supplied by a peer.
  @spec ensure(Path.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def ensure(root, host, relocation, placement) do
    locked(root, host, relocation, placement, fn directory, binding ->
      with {:ok, state} <- load(directory, binding, "pending") do
        case state["state"] do
          "retired" ->
            {:error, :transfer_key_retired}

          "ready" ->
            with {:ok, public} <- public_key(directory),
                 true <- public == state["public_key"],
                 do: {:ok, public},
                 else: (_ -> {:error, :invalid_transfer_key_state})

          "pending" ->
            with {:ok, public} <- prepare(directory),
                 {:ok, _} <- Command.run(:sync, ["--", Path.join(directory, @key)]),
                 :ok <- remove_public_file(directory),
                 :ok <- save(directory, %{state | "state" => "ready", "public_key" => public}) do
              published(relocation, placement, public)
            end
        end
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] transfer-key-retirement-is-permanent
  # retire/4 MUST publish a permanent tombstone before erasing private material,
  # including when cancellation precedes generation. Success requires synced
  # removal. Callers MUST separately revoke the source permit and confirm streams
  # terminated: deleting a key file does not revoke an established SSH connection.
  @spec retire(Path.t(), String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def retire(root, host, relocation, placement) do
    locked(root, host, relocation, placement, fn directory, binding ->
      fresh = absent?(Path.join(directory, "key.json"))

      with {:ok, state} <- load(directory, binding, "retired"),
           :ok <- save(directory, %{state | "state" => "retired"}),
           :ok <- remove_private_file(directory),
           :ok <- remove_public_file(directory),
           {:ok, _} <- Command.run(:sync, ["--", directory]),
           do: retired(relocation, placement, fresh or state["state"] != "retired")
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] local-transfer-rechecks-key-tombstone
  # Local copy/adoption callers MUST hold receive ownership while checking the
  # existing ready key. This never creates a key or resurrects retired authority;
  # retirement must subsequently acquire that same ownership before acknowledging.
  @spec ready(Path.t(), String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def ready(root, host, relocation, placement) do
    locked(root, host, relocation, placement, fn directory, binding ->
      with {:ok, _} <- PrivateFiles.read_secret(Path.join(directory, "key.json")),
           {:ok, %{"state" => "ready", "public_key" => public}} <-
             load(directory, binding, "pending"),
           {:ok, ^public} <- public_key(directory),
           do: :ok,
           else: (_ -> {:error, :transfer_key_unconfirmed})
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] transfer-client-files-bind-enrolled-peer
  # connection/6 MUST require the existing ready private key and exact published
  # public key. It MUST permanently bind the enrolled source endpoint before
  # publishing a private known-hosts file, rejecting peer/pin changes on retry.
  # It MUST NOT generate credentials or resurrect retired keys. Returned paths
  # and the verified public key do not grant a permit: callers must fence streams and revoke source authority
  # independently when cancellation races an already prepared SSH connection.
  @spec connection(Path.t(), String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok,
           %{
             identity_file: Path.t(),
             known_hosts: Path.t(),
             stream_dir: Path.t(),
             public_key: String.t()
           }}
          | {:error, atom()}
  def connection(root, host, relocation, placement, source, endpoint) do
    with true <- OverallsProtocol.uuid?(source) and source != host,
         {:ok, endpoint} <- OverallsProtocol.TransferSSH.endpoint(endpoint) do
      locked(root, host, relocation, placement, fn directory, binding ->
        expected = %{"version" => 3, "source_host_id" => source, "endpoint" => endpoint}
        known = "lilly-" <> source <> " " <> endpoint["host_key"] <> "\n"

        with {:ok, _} <- PrivateFiles.read_secret(Path.join(directory, "key.json")),
             {:ok, %{"state" => "ready", "public_key" => public} = state} <-
               load(directory, binding, "pending"),
             {:ok, ^public} <- public_key(directory),
             :ok <- bind_connection(directory, state, expected),
             :ok <- known_hosts(directory, known) do
          {:ok,
           %{
             public_key: public,
             identity_file: Path.join(directory, @key),
             known_hosts: Path.join(directory, "known_hosts"),
             stream_dir: Path.join(directory, "stream")
           }}
        else
          _ -> {:error, :invalid_transfer_connection}
        end
      end)
    else
      _ -> {:error, :invalid_transfer_connection}
    end
  end

  # @cc [owner:ghuntley,label:security;observability] key-lifecycle-events-correlated
  # Publication and permanent-erasure events MUST carry only the relocation and
  # placement identifiers; public keys, private key material, paths and journal
  # contents MUST NOT be logged. Events fire only on the durable state
  # transition, so idempotent retries of an already ready or retired key MUST
  # NOT re-emit.
  defp published(relocation, placement, public) do
    Lilly.Events.emit("lilly.key_created", relocation_id: relocation, placement_id: placement)
    {:ok, public}
  end

  defp retired(relocation, placement, true) do
    Lilly.Events.emit("lilly.key_retired", relocation_id: relocation, placement_id: placement)
    :ok
  end

  defp retired(_, _, false), do: :ok

  defp bind_connection(directory, %{"connection" => nil} = state, expected) do
    if absent?(Path.join(directory, "known_hosts")),
      do: save(directory, %{state | "connection" => expected}),
      else: :error
  end

  defp bind_connection(_, %{"connection" => expected}, expected), do: :ok
  defp bind_connection(_, _, _), do: :error

  defp known_hosts(directory, expected) do
    case File.lstat(Path.join(directory, "known_hosts")) do
      {:error, :enoent} ->
        PrivateFiles.write(directory, "known_hosts", expected)

      {:ok, _} ->
        with {:ok, ^expected} <- PrivateFiles.read_secret(Path.join(directory, "known_hosts")),
             do: :ok

      _ ->
        :error
    end
  end

  defp locked(root, host, relocation, placement, function) do
    with true <- Enum.all?([host, relocation, placement], &OverallsProtocol.uuid?/1),
         true <- is_binary(root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         :ok <- PrivateFiles.directory(root),
         parent = Path.join(root, "transfers"),
         :ok <- PrivateFiles.directory(parent),
         directory = Path.join(parent, relocation),
         {:ok, lock} <- Lock.acquire(directory) do
      binding = %{
        "version" => 3,
        "host_id" => host,
        "relocation_id" => relocation,
        "placement_id" => placement
      }

      try do
        case function.(directory, binding) do
          result when result == :ok or (is_tuple(result) and elem(result, 0) == :ok) ->
            # Persist newly created directory entries before publishing a key or
            # acknowledging retirement. Syncing the leaf alone is insufficient.
            with {:ok, _} <- Command.run(:sync, ["--", parent, root]), do: result

          error ->
            error
        end
      after
        Lock.release(lock)
      end
    else
      _ -> {:error, :invalid_transfer_identity}
    end
  end

  defp load(directory, binding, initial) do
    case File.lstat(Path.join(directory, "key.json")) do
      {:error, :enoent} ->
        with true <-
               absent?(Path.join(directory, @key)) and
                 absent?(Path.join(directory, @key <> ".pub")),
             state =
               Map.merge(binding, %{"state" => initial, "public_key" => nil, "connection" => nil}),
             :ok <- save(directory, state),
             do: {:ok, state},
             else: (_ -> {:error, :invalid_transfer_key_state})

      {:ok, _} ->
        with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, "key.json")),
             {:ok, state} when is_map(state) and map_size(state) == 7 <- JSON.decode(bytes),
             true <- Map.take(state, Map.keys(binding)) == binding,
             true <- valid_state?(state) and valid_connection?(state["connection"]),
             do: {:ok, state},
             else: (_ -> {:error, :invalid_transfer_key_state})

      _ ->
        {:error, :invalid_transfer_key_state}
    end
  end

  defp valid_connection?(nil), do: true

  defp valid_connection?(
         %{"version" => 3, "source_host_id" => source, "endpoint" => endpoint} = value
       )
       when map_size(value) == 3 do
    OverallsProtocol.uuid?(source) and
      match?({:ok, _}, OverallsProtocol.TransferSSH.endpoint(endpoint))
  end

  defp valid_connection?(_), do: false

  defp valid_state?(%{"state" => "pending", "public_key" => nil}), do: true
  defp valid_state?(%{"state" => "retired", "public_key" => nil}), do: true

  defp valid_state?(%{"state" => state, "public_key" => public})
       when state in ["ready", "retired"],
       do: valid_public?(public)

  defp valid_state?(_), do: false

  defp prepare(directory) do
    case File.lstat(Path.join(directory, @key)) do
      {:error, :enoent} ->
        generate(directory)

      {:ok, _} ->
        case public_key(directory) do
          {:error, :command_failed} ->
            with :ok <- remove_private_file(directory), do: generate(directory)

          result ->
            result
        end

      _ ->
        {:error, :invalid_transfer_key_state}
    end
  end

  defp generate(directory) do
    with :ok <- remove_public_file(directory),
         {:ok, _} <-
           Command.run(
             :ssh_keygen,
             ["-q", "-t", "ed25519", "-N", "", "-C", "", "-f", Path.join(directory, @key)],
             10_000
           ),
         do: public_key(directory)
  end

  defp public_key(directory) do
    path = Path.join(directory, @key)

    with {:ok, _private} <- PrivateFiles.read_secret(path),
         {:ok, output} <- Command.run(:ssh_keygen, ["-y", "-f", path]),
         public = String.trim_trailing(output, "\n"),
         true <- valid_public?(public),
         do: {:ok, public},
         else: (
           false -> {:error, :invalid_transfer_key_state}
           error -> error
         )
  end

  defp valid_public?(value), do: OverallsProtocol.TransferSSH.public_key?(value)

  defp remove_private_file(directory) do
    path = Path.join(directory, @key)

    if absent?(path),
      do: :ok,
      else:
        with(
          {:ok, _private} <- PrivateFiles.read_secret(path),
          {:ok, _} <- Command.run(:rm, ["--", path]),
          do: :ok
        )
  end

  defp remove_public_file(directory) do
    path = Path.join(directory, @key <> ".pub")

    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular, links: 1, uid: owner}} ->
        {:ok, %{uid: uid}} = File.stat("/proc/self")

        if owner == uid do
          with {:ok, _} <- Command.run(:rm, ["--", path]), do: :ok
        else
          {:error, :invalid_transfer_key_state}
        end

      _ ->
        {:error, :invalid_transfer_key_state}
    end
  end

  defp absent?(path), do: File.lstat(path) == {:error, :enoent}
  defp save(directory, state), do: PrivateFiles.write(directory, "key.json", JSON.encode!(state))
end
