defmodule Lilly.Transfer.PermitJournal do
  @moduledoc "Durable source probe/export leases and permanent relocation revocation fences."
  alias OverallsProtocol.TransferSSH
  alias OverallsProtocol.DiskTransfer, as: Relocation
  alias Lilly.Host.{Command, Lock, PrivateFiles}
  @maximum 9_223_372_036_854_775_807
  @lease_seconds 300
  @type failure :: {:error, :export_permit_unconfirmed}

  # @cc [owner:ghuntley,label:security;recovery] export-preparation-grants-no-access
  # prepare/3 MUST initialize an unissued record atomically before a first stream
  # lock is acquired. It MUST preserve existing grants and reject revoked or
  # corrupt state without repairing it. Preparation does not grant export access.
  @spec prepare(Path.t(), String.t(), String.t()) :: :ok | failure()
  def prepare(root, host, relocation) do
    mutate(root, host, relocation, fn
      %{"state" => state} = record when state in ["unissued", "probing", "active"] ->
        {:ok, record}

      _ ->
        :error
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] probe-grants-never-authorize-export
  # probe/7 requires authenticated current relocation authority and reserved
  # endpoints. It MUST bind the immutable intent, key and challenge, expire within
  # 300 seconds, and never revive revoked state or replace an export grant.
  # Renewals MUST increase revision without shortening expiry or changing identity.
  # Probe grants MUST NOT resolve through the snapshot-export lookup functions.
  @spec probe(Path.t(), map(), String.t(), String.t(), pos_integer(), integer(), integer()) ::
          :ok | failure()
  def probe(root, wire, public, challenge, revision, expires, now) do
    with {:ok, intent} <- Relocation.intent(wire),
         true <- TransferSSH.public_key?(public) and OverallsProtocol.uuid?(challenge),
         true <- revision?(revision) and time?(now),
         true <- is_integer(expires) and expires > now and expires <= now + @lease_seconds do
      grant = %{
        "intent" => wire,
        "public_key" => public,
        "challenge" => challenge,
        "revision" => revision,
        "issued_at" => now,
        "expires_at" => expires
      }

      mutate(root, intent.source.host_id, intent.relocation_id, fn
        %{"state" => "unissued", "grant" => nil} = record ->
          {:ok, %{record | "state" => "probing", "grant" => grant}}

        %{"state" => "probing", "grant" => previous} = record ->
          cond do
            now < previous["issued_at"] ->
              :error

            Map.delete(grant, "issued_at") == Map.delete(previous, "issued_at") ->
              {:ok, record}

            revision > previous["revision"] and expires >= previous["expires_at"] and
                Map.take(grant, ["intent", "public_key", "challenge"]) ==
                  Map.take(previous, ["intent", "public_key", "challenge"]) ->
              {:ok, %{record | "grant" => grant}}

            true ->
              :error
          end

        _ ->
          :error
      end)
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security] probe-lookup-is-only-connectivity-authority
  # lookup_probe/6 MUST require the authenticated SSH key and exact challenge,
  # rejecting future-issued, expired, revoked or export-active records. Success
  # permits only a bounded challenge response, never storage access or execution.
  @spec lookup_probe(Path.t(), String.t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | failure()
  def lookup_probe(root, host, relocation, public, challenge, now) do
    with true <- identity?(host, relocation) and time?(now) and TransferSSH.public_key?(public),
         true <- OverallsProtocol.uuid?(challenge),
         {:ok, %{"state" => "probing", "grant" => grant}} <-
           read(directory(root, relocation), host, relocation),
         true <- grant["public_key"] == public and grant["challenge"] == challenge,
         true <- grant["issued_at"] <= now and now < grant["expires_at"],
         {:ok, intent} <- Relocation.intent(grant["intent"]) do
      {:ok, %{intent: intent, revision: grant["revision"], expires_at: grant["expires_at"]}}
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] export-grants-preserve-peer-and-lineage
  # grant/6 requires authenticated current authority, native source verification
  # and reserved capacity. Stream advancement additionally requires old streams
  # and waiting launchers to be quiescent. It MUST bind the peer key and descriptor
  # identity permanently, accept only increasing revisions of the identical
  # descriptor or identical retries, and never revive a revoked relocation. A
  # probe may advance only to an export with the same intent and key; a memory
  # relocation's checkpoint is captured after its running-source probe, so only
  # that descriptor field is excluded from the probe comparison. New leases
  # MUST expire within 300 seconds of local time.
  @spec grant(Path.t(), map(), String.t(), pos_integer(), integer(), integer()) :: :ok | failure()
  def grant(root, wire, public, revision, expires, now) do
    with {:ok, descriptor} <- Relocation.descriptor(wire),
         true <- TransferSSH.public_key?(public) and revision?(revision),
         true <-
           time?(now) and is_integer(expires) and expires > now and
             expires <= now + @lease_seconds do
      mutate(root, descriptor.source.host_id, descriptor.relocation_id, fn record ->
        grant = %{
          "descriptor" => wire,
          "public_key" => public,
          "revision" => revision,
          "issued_at" => now,
          "expires_at" => expires
        }

        case record do
          %{"state" => "unissued", "grant" => nil} ->
            {:ok, %{record | "state" => "active", "grant" => grant}}

          %{"state" => "probing", "grant" => previous} ->
            if previous["public_key"] == public and
                 previous["intent"] == Map.drop(wire, ["stream", "checkpoint"]) and
                 now >= previous["issued_at"] do
              {:ok, %{record | "state" => "active", "grant" => grant}}
            else
              :error
            end

          %{"state" => "active", "grant" => previous} ->
            cond do
              now < previous["issued_at"] ->
                :error

              Map.drop(grant, ["issued_at"]) == Map.drop(previous, ["issued_at"]) ->
                {:ok, record}

              revision > previous["revision"] and expires >= previous["expires_at"] and
                  Map.take(previous, ["descriptor", "public_key"]) ==
                    Map.take(grant, ["descriptor", "public_key"]) ->
                {:ok, %{record | "grant" => grant}}

              true ->
                :error
            end

          _ ->
            :error
        end
      end)
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] export-revocation-is-a-permanent-fence
  # fence/3 MUST persist revocation even before the first grant and retain prior
  # grant history. Success is only the durable fence, not active-channel revocation
  # or quiescence. The caller MUST kill/reap existing and waiting exporters before
  # acknowledging full revocation or releasing snapshots, reservations or slots.
  @spec fence(Path.t(), String.t(), String.t()) :: :ok | failure()
  def fence(root, host, relocation) do
    mutate(root, host, relocation, fn record -> {:ok, %{record | "state" => "revoked"}} end)
  end

  # @cc [owner:ghuntley,label:security] export-lookup-is-not-a-launch-transaction
  # lookup/5 MUST require exact authenticated SSH public key and host identity,
  # rejecting expired, future-issued, revoked, missing or corrupt records.
  # Returned state is a snapshot, not permission to launch across a concurrent
  # fence. Callers MUST serialize launch registration with revocation, revalidate
  # native ownership and enforce lease updates with a monotonic runtime deadline.
  @spec lookup(Path.t(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | failure()
  def lookup(root, host, relocation, public, now) do
    with true <- identity?(host, relocation) and time?(now) and TransferSSH.public_key?(public),
         {:ok, %{"state" => "active", "grant" => grant}} <-
           read(directory(root, relocation), host, relocation),
         true <- grant["public_key"] == public,
         true <- grant["issued_at"] <= now and now < grant["expires_at"],
         {:ok, descriptor} <- Relocation.descriptor(grant["descriptor"]) do
      {:ok,
       %{descriptor: descriptor, revision: grant["revision"], expires_at: grant["expires_at"]}}
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security] ssh-key-index-is-not-authentication
  # for_key/4 MUST resolve only an exact durable key binding and a currently active
  # permit for this host. Missing/corrupt indices MUST fail closed without repair.
  # The SSH server still MUST verify possession of the corresponding private key;
  # this read-only result does not authorize a launch across concurrent revocation.
  @spec for_key(Path.t(), String.t(), String.t(), integer()) :: {:ok, map()} | failure()
  def for_key(root, host, public, now) do
    with true <- OverallsProtocol.uuid?(host) and TransferSSH.public_key?(public) and time?(now),
         {:ok, binding} <- read_key(root, public),
         %{
           "version" => 3,
           "host_id" => ^host,
           "public_key" => ^public,
           "relocation_id" => relocation
         }
         when map_size(binding) == 4 <- binding,
         true <- OverallsProtocol.uuid?(relocation) do
      lookup(root, host, relocation, public, now)
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security] ssh-authentication-preserves-grant-kind
  # authentication/4 MUST resolve an exact durable key index and live export or
  # probe grant. It MUST return the source identity only, never an export descriptor
  # for a probe. Command dispatch MUST independently revalidate the requested grant.
  @spec authentication(Path.t(), String.t(), String.t(), integer()) :: {:ok, map()} | failure()
  def authentication(root, host, public, now) do
    case for_key(root, host, public, now) do
      {:ok, grant} ->
        {:ok, grant.descriptor.source}

      _ ->
        with true <-
               OverallsProtocol.uuid?(host) and TransferSSH.public_key?(public) and time?(now),
             {:ok, binding} <- read_key(root, public),
             %{
               "version" => 3,
               "host_id" => ^host,
               "public_key" => ^public,
               "relocation_id" => relocation
             }
             when map_size(binding) == 4 <- binding,
             true <- OverallsProtocol.uuid?(relocation),
             {:ok, %{"state" => "probing", "grant" => grant}} <-
               read(directory(root, relocation), host, relocation),
             {:ok, probe} <- lookup_probe(root, host, relocation, public, grant["challenge"], now) do
          {:ok, probe.intent.source}
        else
          _ -> failure()
        end
    end
  end

  # @cc [owner:ghuntley,label:recovery] permit-directory-publication-is-atomic
  # New canonical directories MUST appear only with a synced unissued record.
  # Existing directories with missing/corrupt records MUST NOT be reinitialized.
  # The stable parent lock serializes mutations; private unpublished staging is
  # never eligible for lookup. Failed publication retains uncertainty and MUST NOT
  # remove a directory that may already have become authoritative.
  defp mutate(root, host, relocation, function) do
    with true <- identity?(host, relocation),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         :ok <- PrivateFiles.directory(root),
         parent = Path.join(root, "exports"),
         :ok <- PrivateFiles.directory(parent),
         {:ok, lock} <- Lock.acquire(parent) do
      try do
        directory = directory(root, relocation)

        with :ok <- initialize(parent, directory, host, relocation),
             {:ok, record} <- read(directory, host, relocation),
             {:ok, changed} <- function.(record),
             :ok <- bind_key(root, record, changed),
             :ok <-
               Lilly.Lifecycle.Journal.write(
                 Lilly.Lifecycle.Permit,
                 directory,
                 "permit.json",
                 changed
               ),
             {:ok, _} <- Command.run(:sync, ["--", parent, root]),
             do: :ok,
             else: (_ -> failure())
      after
        Lock.release(lock)
      end
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] export-keys-bind-once-before-grant
  # Under the export mutation lock, an initial grant MUST durably bind its public
  # key to exactly one host/relocation before publishing a probe or export permit. Existing
  # grants MUST NOT reconstruct missing indices. Bindings persist after revocation;
  # a failed initial publication may leave a binding but cannot grant export access.
  # Fencing MUST remain possible independently of missing/corrupt key index state.
  defp bind_key(root, previous, %{"state" => state, "grant" => grant} = changed)
       when state in ["probing", "active"] do
    public = grant["public_key"]

    expected = %{
      "version" => 3,
      "host_id" => changed["host_id"],
      "relocation_id" => changed["relocation_id"],
      "public_key" => public
    }

    case File.lstat(key_path(root, public)) do
      {:error, :enoent} when :erlang.map_get("state", previous) == "unissued" ->
        parent = Path.join([root, "exports", "keys"])

        with :ok <- PrivateFiles.directory(parent),
             :ok <-
               PrivateFiles.write(
                 parent,
                 Path.basename(key_path(root, public)),
                 JSON.encode!(expected)
               ),
             {:ok, _} <- Command.run(:sync, ["--", Path.dirname(parent)]),
             do: :ok

      {:ok, _} ->
        case read_key(root, public) do
          {:ok, ^expected} -> :ok
          _ -> failure()
        end

      _ ->
        failure()
    end
  end

  defp bind_key(_, _, _), do: :ok

  defp read_key(root, public) do
    with {:ok, bytes} <- PrivateFiles.read_secret(key_path(root, public)),
         {:ok, binding} <- JSON.decode(bytes),
         do: {:ok, binding},
         else: (_ -> failure())
  end

  defp key_path(root, public) do
    name = :crypto.hash(:sha256, public) |> Base.encode16(case: :lower)
    Path.join([root, "exports", "keys", name <> ".json"])
  end

  defp initialize(parent, directory, host, relocation) do
    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        staged =
          Path.join(
            parent,
            ".pending-" <>
              relocation <> "-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
          )

        initial = %{
          "version" => 3,
          "host_id" => host,
          "relocation_id" => relocation,
          "state" => "unissued",
          "grant" => nil
        }

        with :ok <- PrivateFiles.directory(staged),
             :ok <-
               Lilly.Lifecycle.Journal.write(
                 Lilly.Lifecycle.Permit,
                 staged,
                 "permit.json",
                 initial
               ),
             {:ok, _} <- Command.run(:mv, ["--no-target-directory", "--", staged, directory]),
             {:ok, _} <- Command.run(:sync, ["--", parent]),
             do: :ok

      _ ->
        :error
    end
  end

  defp read(directory, host, relocation) do
    with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, "permit.json")),
         {:ok,
          %{
            "version" => 3,
            "host_id" => ^host,
            "relocation_id" => ^relocation,
            "state" => state,
            "grant" => grant
          } = record}
         when map_size(record) == 5 <- Lilly.Lifecycle.Journal.decode(bytes),
         true <- valid_state?(state, grant, host, relocation),
         do: {:ok, record},
         else: (_ -> failure())
  end

  defp valid_state?(state, nil, _, _), do: state in ["unissued", "revoked"]

  defp valid_state?(
         state,
         %{
           "descriptor" => wire,
           "public_key" => public,
           "revision" => revision,
           "issued_at" => issued,
           "expires_at" => expires
         } = grant,
         host,
         relocation
       )
       when map_size(grant) == 5 and state in ["active", "revoked"] do
    with {:ok, descriptor} <- Relocation.descriptor(wire),
         true <- descriptor.source.host_id == host and descriptor.relocation_id == relocation,
         true <- TransferSSH.public_key?(public) and revision?(revision) and time?(issued),
         true <- is_integer(expires) and expires > issued and expires <= issued + @lease_seconds,
         do: true,
         else: (_ -> false)
  end

  defp valid_state?(
         state,
         %{
           "intent" => wire,
           "public_key" => public,
           "challenge" => challenge,
           "revision" => revision,
           "issued_at" => issued,
           "expires_at" => expires
         } = grant,
         host,
         relocation
       )
       when map_size(grant) == 6 and state in ["probing", "revoked"] do
    with {:ok, intent} <- Relocation.intent(wire),
         true <- intent.source.host_id == host and intent.relocation_id == relocation,
         true <- TransferSSH.public_key?(public) and OverallsProtocol.uuid?(challenge),
         true <- revision?(revision) and time?(issued),
         true <- is_integer(expires) and expires > issued and expires <= issued + @lease_seconds,
         do: true,
         else: (_ -> false)
  end

  defp valid_state?(_, _, _, _), do: false

  defp identity?(host, relocation),
    do: OverallsProtocol.uuid?(host) and OverallsProtocol.uuid?(relocation)

  defp revision?(value), do: is_integer(value) and value in 1..@maximum
  defp time?(value), do: is_integer(value) and value in 0..(@maximum - @lease_seconds)
  defp directory(root, relocation), do: Path.join([root, "exports", relocation])
  defp failure, do: {:error, :export_permit_unconfirmed}
end
