defmodule Marshall.Compute.Enrollment do
  @moduledoc "Trusted operator file workflow. Never expose these functions as public user actions."
  import Marshall.Compute.CredentialLifetime, only: [valid: 1]

  alias Marshall.Compute.{
    Credentials,
    EnrollmentRequest,
    Host,
    HostCredential,
    HostDrain,
    Ledger,
    StoragePool
  }

  alias Marshall.Operations.{PrivateFiles, Privacy}
  require Marshall.Events
  require Ash.Query

  # @cc [owner:ghuntley,label:security] enrollment-disabled-unobserved-host
  # Enrollment MUST create a disabled host with no fabricated capacity, enrolled
  # pools and its credential in one database transaction. The secret MUST leave
  # this boundary only in the newly created private output file.
  @spec enroll_file(Path.t(), Path.t()) :: {:ok, map()} | {:error, atom()}
  def enroll_file(request_path, output_path) do
    Privacy.run(fn ->
      with {:ok, encoded} <- PrivateFiles.read(request_path),
           {:ok, input} <- JSON.decode(encoded),
           {:ok, request} <- EnrollmentRequest.parse(input) do
        issue_file(output_path, fn ->
          reserve_name(request)

          host = Ledger.create!(Host, :enroll, request.host)

          for pool <- request.pools,
              do: Ledger.create!(StoragePool, :enroll, Map.put(pool, :host_id, host.id))

          {host, request.ttl}
        end)
      else
        _ -> {:error, :invalid_enrollment_request}
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;concurrency] enroll-name-lock-retired-fence
  # Manual enrollment MUST hold the same per-name advisory lock as preparation
  # before consulting authority, so manual and prepared operators serialize.
  # An existing row for the name MUST refuse precisely: a retired host refuses
  # forever (:host_retired; its name is never recycled) and any other existing
  # registration conflicts (:registration_conflict). The unique name and machine
  # identities remain the backstop, not the only fence.
  @spec reserve_name(map()) :: :ok
  defp reserve_name(request) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["enrollment:" <> request.host.name],
      log: false
    )

    case Ledger.read!(Host, name: request.host.name) do
      [] ->
        :ok

      [%{maintenance_mode: :retired}] ->
        Ledger.rollback(:host_retired)

      [_] ->
        Ledger.rollback(:registration_conflict)
    end
  end

  @spec rotate_file(String.t(), pos_integer(), Path.t()) :: {:ok, map()} | {:error, atom()}
  def rotate_file(host_id, ttl, output_path) do
    Privacy.run(fn ->
      if OverallsProtocol.uuid?(host_id) and valid(ttl) do
        issue_file(output_path, fn ->
          host = Ledger.lock!(Host, host_id)
          unless host, do: Ledger.rollback(:unknown_host)
          if host.maintenance_mode == :retired, do: Ledger.rollback(:host_retired)
          {host, ttl}
        end)
      else
        {:error, :invalid_rotation_request}
      end
    end)
  end

  # @cc [owner:ghuntley,label:recovery] enrollment-verification-distinguishes-unavailable
  # Verification MUST bind the envelope's host, credential ID and expiry to
  # current authenticated database authority. Failed database/decryption access
  # MUST report verification_unavailable, not credential_inactive.
  @spec verify_file(Path.t()) :: {:ok, map()} | {:error, atom()}
  def verify_file(path), do: Privacy.run(fn -> verify(path) end)

  defp verify(path) do
    with {:ok, encoded} <- PrivateFiles.read(path),
         {:ok,
          %{
            "version" => 1,
            "host_id" => host_id,
            "credential_id" => id,
            "credential" => token,
            "expires_at" => expiry
          } = envelope} <- JSON.decode(encoded),
         true <-
           map_size(envelope) == 5 and OverallsProtocol.uuid?(host_id) and
             OverallsProtocol.uuid?(id) and is_binary(token) and is_binary(expiry) do
      case Credentials.with_host(token, fn host ->
             unless host.id == host_id, do: Ledger.rollback(:invalid_credential_file)

             case Ledger.read!(HostCredential, id: id, host_id: host_id) do
               [credential] ->
                 unless DateTime.to_iso8601(credential.expires_at) == expiry and
                          String.starts_with?(token, id <> ":"),
                        do: Ledger.rollback(:invalid_credential_file)

                 public(host, credential)

               _ ->
                 Ledger.rollback(:invalid_credential_file)
             end
           end) do
        {:ok, public} -> {:ok, public}
        {:error, :unauthorized} -> {:error, :credential_inactive}
        {:error, :invalid_credential_file} -> {:error, :invalid_credential_file}
        _ -> {:error, :verification_unavailable}
      end
    else
      _ -> {:error, :invalid_credential_file}
    end
  rescue
    _ -> {:error, :verification_unavailable}
  end

  @spec describe(String.t()) :: {:ok, map()} | {:error, atom()}
  def describe(name) do
    Privacy.run(fn ->
      case Ledger.read!(Host, name: name) do
        [host] ->
          Ledger.transaction(fn ->
            host = Ledger.lock!(Host, host.id)
            public(host, List.first(Ledger.read!(HostCredential, host_id: host.id)))
          end)

        _ ->
          {:error, :unknown_host}
      end
    end)
  end

  @spec revoke(String.t()) :: {:ok, map()} | {:error, atom()}
  def revoke(host_id) do
    Privacy.run(fn ->
      with true <- OverallsProtocol.uuid?(host_id), {:ok, :ok} <- Credentials.revoke(host_id) do
        Marshall.Events.emit("host.credentials_revoked", host_id: host_id)

        {:ok, %{host_id: host_id, revoked: true}}
      else
        _ -> {:error, :revocation_failed}
      end
    end)
  end

  @spec set_enabled(String.t(), boolean()) :: {:ok, map()} | {:error, atom()}
  def set_enabled(host_id, enabled) when is_boolean(enabled) do
    Privacy.run(fn ->
      result =
        Ledger.transaction(fn ->
          host = Ledger.lock!(Host, host_id)
          unless host, do: Ledger.rollback(:unknown_host)

          if enabled and host.maintenance_mode != :normal,
            do: Ledger.rollback(:host_in_maintenance)

          if enabled and
               not (host.inventory["execution_ready"] == true and
                      Marshall.Compute.HostLiveness.capacity_fresh?(
                        host.reported_at,
                        Ledger.now()
                      )),
             do: Ledger.rollback(:host_not_ready)

          Ledger.update!(host, :configure, %{enabled: enabled})
          %{host_id: host_id, enabled: enabled}
        end)

      case result do
        {:ok, metadata} ->
          Marshall.Events.emit("host.admission_changed",
            host_id: host_id,
            operation_status: if(enabled, do: :enabled, else: :disabled)
          )

          {:ok, metadata}

        {:error, reason} when reason in [:host_not_ready, :host_in_maintenance] ->
          {:error, reason}

        _ ->
          {:error, :host_configuration_failed}
      end
    end)
  end

  # @cc [owner:ghuntley,label:recovery] enrollment-file-database-crash-boundary
  # Issuance MUST reserve a new private destination before creating authority and
  # sync its credential envelope before database commit. Write failures MUST roll
  # back database changes; a retained file after failure MUST require verification
  # and MUST NOT be overwritten or represented as proof of a committed credential.
  # Refusal reasons raised before any issuance (:host_retired, :registration_conflict)
  # MUST surface unchanged; uncertain issuance outcomes collapse to the generic
  # issuance_failed_verify_output class.
  defp issue_file(path, prepare) do
    PrivateFiles.with_new(path, fn file ->
      result =
        Ledger.transaction(fn ->
          {host, ttl} = prepare.()
          {:ok, issued} = Credentials.rotate(host.id, ttl)

          envelope = %{
            version: 1,
            host_id: host.id,
            credential_id: issued.id,
            credential: issued.token,
            expires_at: DateTime.to_iso8601(issued.expires_at)
          }

          unless PrivateFiles.write_sync(file, path, JSON.encode!(envelope) <> "\n") == :ok,
            do: Ledger.rollback(:credential_file_write_failed)

          public(host, issued)
        end)

      case result do
        {:ok, public} ->
          Marshall.Events.emit("host.credential_file_issued", host_id: public.host_id)

          {:ok, public}

        {:error, reason} when reason in [:host_retired, :registration_conflict] ->
          {:error, reason}

        _ ->
          {:error, :issuance_failed_verify_output}
      end
    end)
  end

  defp public(host, credential) do
    drain =
      HostDrain
      |> Ash.Query.filter(host_id == ^host.id and is_nil(closed_at))
      |> Ash.read_one!(actor: Marshall.Authorization.SystemActor.compute())

    %{
      host_id: host.id,
      name: host.name,
      enabled: host.enabled,
      maintenance_mode: Atom.to_string(host.maintenance_mode),
      active_drain_id: drain && drain.id,
      machine_id: host.machine_id,
      transfer_endpoint: host.transfer_endpoint,
      architecture: Atom.to_string(host.architecture),
      credential_id: credential && credential.id,
      expires_at: credential && DateTime.to_iso8601(credential.expires_at),
      pools:
        Enum.map(
          Ledger.read!(StoragePool, host_id: host.id),
          &StoragePool.descriptor/1
        )
    }
  end
end
