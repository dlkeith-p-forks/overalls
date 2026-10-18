defmodule Lilly.Transfer.SourceExport do
  @moduledoc "Source export registration, durable lease supervision and confirmed revocation."
  require Lilly.Events
  alias OverallsProtocol.DiskTransfer, as: Relocation
  alias Lilly.Host.{Lock, Pool, Storage}
  alias Lilly.Transfer.{Exporter, ExportRequest, PermitJournal, SourceSnapshots}
  @type failure :: {:error, atom()}

  # @cc [owner:ghuntley,label:security;recovery] source-export-registration-is-fenced
  # run/4 requires the dedicated authenticated export subprocess: stdout is its
  # remote data channel, and public is the SSH-server-authenticated key, never a
  # client-selected identity. Pool/root are trusted local configuration. Under the
  # pool lock then permit mutation lock it MUST recheck the key index, lease and
  # native ownership and register the sender before dropping either lock. Waiting
  # MUST retain only transfer ownership and enforce revocation, expiry and exact
  # descriptor identity. A successful send is not destination import verification.
  # Initial pool acquisition may retry contention for two seconds; all permit and
  # native checks MUST occur after acquisition, without replaying registration.
  @spec run(Path.t(), Pool.t(), String.t(), String.t()) :: :ok | failure()
  def run(root, pool, public, command) do
    result = Storage.locked(pool, fn -> register(root, pool, public, command) end, 2000)

    case result do
      {:ok, sender, authority} ->
        Exporter.wait(sender, authority, &refresh(root, pool.host_id, public, command, &1))

      error ->
        error
    end
  end

  defp register(root, pool, public, command) do
    directory = Path.join(root, "exports")

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         {:ok, lock} <- Lock.acquire(directory) do
      try do
        now = System.system_time(:second)

        with {:ok, grant} <- current(root, pool.host_id, public, command, now),
             {:ok, sender_command} <-
               sender_command(pool, grant.descriptor, command),
             # Native ownership checks can take time; lease is re-read immediately
             # before spawning while the mutation lock still excludes revocation.
             {:ok, latest} <-
               current(root, pool.host_id, public, command, System.system_time(:second)),
             true <- latest == grant,
             ttl = (latest.expires_at - System.system_time(:second)) * 1000,
             true <- ttl in 1..300_000,
             deadline = System.monotonic_time(:millisecond) + ttl,
             {:ok, sender} <-
               Exporter.start(
                 stream_directory(root, grant.descriptor.relocation_id),
                 sender_command,
                 ttl
               ) do
          {:ok, sender, Map.put(grant, :deadline, deadline)}
        else
          {:error, reason} when is_atom(reason) -> rejected(reason)
          _ -> rejected(:export_permit_unconfirmed)
        end
      after
        Lock.release(lock)
      end
    else
      _ -> rejected(:export_permit_unconfirmed)
    end
  end

  # @cc [owner:ghuntley,label:security;observability] export-registration-failure-closed
  # A rejected registration MUST report only the closed reason atom; keys,
  # request text, descriptors and native argv MUST NOT be logged. Confirmed
  # revocations and lease renewals emit nothing here: their outcomes belong to
  # the terminal callers that own the relocation identifiers, and the export
  # worker classifies its own final status.
  defp rejected(reason) do
    Lilly.Events.emit("lilly.transfer_export_failed", reason: reason)
    {:error, reason}
  end

  # @cc [owner:ghuntley,label:security] resumed-export-rechecks-native-source-lineage
  # Resumed sends MUST use the current permit descriptor and native token validator
  # under the same pool/permit registration locks as ordinary exports. A token
  # MUST NOT replace permit identity, native ownership, lease or revocation checks.
  defp sender_command(pool, descriptor, command) do
    with {:ok, request} <- ExportRequest.parse(command) do
      wire = Relocation.encode_descriptor(descriptor)

      case request do
        %{component: :checkpoint} -> Lilly.Transfer.CheckpointTransfer.export(pool, descriptor)
        %{resume_token: token} -> SourceSnapshots.resume_export(pool, wire, token)
        _ -> SourceSnapshots.export(pool, wire)
      end
    end
  end

  defp current(root, host, public, command, now) do
    with {:ok, grant} <- PermitJournal.for_key(root, host, public, now),
         {:ok, ^grant} <- ExportRequest.lookup(root, host, public, command, now),
         do: {:ok, grant}
  end

  # @cc [owner:ghuntley,label:security] lease-renewal-preserves-monotonic-expiry
  # Only a newer revision of the same descriptor may extend native authority.
  # Re-reading an unchanged lease MUST NOT restart its duration. Renewal MUST
  # increase the old monotonic deadline by at most the signed expiry increase,
  # also bounded by remaining wall-clock validity and 300 seconds. Clock rollback
  # therefore cannot prolong unchanged authority. Corrupt/missing state revokes.
  defp refresh(root, host, public, command, previous) do
    with {:ok, grant} <- current(root, host, public, command, System.system_time(:second)),
         true <- grant.descriptor == previous.descriptor do
      cond do
        grant.revision == previous.revision and grant.expires_at == previous.expires_at ->
          {:ok, previous}

        grant.revision > previous.revision and grant.expires_at >= previous.expires_at ->
          now = System.monotonic_time(:millisecond)

          deadline =
            min(
              previous.deadline + (grant.expires_at - previous.expires_at) * 1000,
              now + (grant.expires_at - System.system_time(:second)) * 1000
            )

          ttl = min(deadline - now, 300_000)

          if ttl > 0,
            do: {{:renew, ttl}, Map.put(grant, :deadline, deadline)},
            else: {:revoke, previous}

        true ->
          {:revoke, previous}
      end
    else
      _ -> {:revoke, previous}
    end
  end

  # @cc [owner:ghuntley,label:recovery] export-revocation-confirms-native-quiescence
  # revoke/3 requires authenticated current coordinator authority and no pool lock.
  # It MUST persist permanent revocation before waiting on the same stable native
  # transfer lock used for registration. Only successful lock acquisition/release
  # or proven absence of any stream directory after fencing confirms quiescence.
  # Timeouts, malformed paths or uncertain lock release MUST retain reservations,
  # snapshots and transfer slots; callers retry without unlinking ownership files.
  @spec revoke(Path.t(), String.t(), String.t()) :: :ok | failure()
  def revoke(root, host, relocation) do
    with true <- is_nil(Lock.current()),
         :ok <- PermitJournal.fence(root, host, relocation) do
      quiescent(stream_directory(root, relocation), System.monotonic_time(:millisecond) + 2000)
    else
      _ -> {:error, :export_revocation_unconfirmed}
    end
  end

  defp quiescent(directory, deadline) do
    case File.lstat(directory) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        case Lock.acquire(directory) do
          {:ok, lock} ->
            Lock.release(lock)

          _ ->
            if System.monotonic_time(:millisecond) < deadline do
              receive do
              after
                25 -> quiescent(directory, deadline)
              end
            else
              {:error, :export_revocation_unconfirmed}
            end
        end

      _ ->
        {:error, :export_revocation_unconfirmed}
    end
  end

  defp stream_directory(root, relocation), do: Path.join([root, "exports", relocation, "stream"])
end
