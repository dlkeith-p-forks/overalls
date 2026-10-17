defmodule Marshall.Compute.EnrollmentPreparation do
  @moduledoc "Idempotent, private-file preparation for authenticated deployment operators."
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Credentials,
    Enrollment,
    EnrollmentOperation,
    EnrollmentRequest,
    Host,
    HostCredential,
    Ledger,
    StoragePool
  }

  alias Marshall.Operations.{PrivateFiles, Privacy}

  # @cc [owner:ghuntley,label:recovery] preparation-retry-authority
  # The operation ID MUST bind the exact request and action transactionally with
  # issuance. A retry MUST export only that still-active credential and MUST NOT
  # rotate again. Conflicting registration, retired hosts and inactive results
  # MUST fail closed. No credential may appear in returned metadata or diagnostics.
  @spec prepare_file(String.t(), :prepare | :rotate, Path.t(), Path.t()) ::
          {:ok, map()} | {:error, atom()}
  def prepare_file(operation_id, kind, request_path, output_path) do
    Privacy.run(fn ->
      with true <- OverallsProtocol.uuid?(operation_id) and kind in [:prepare, :rotate],
           {:ok, bytes} <- PrivateFiles.read(request_path),
           {:ok, input} <- JSON.decode(bytes),
           {:ok, request} <- EnrollmentRequest.parse(input) do
        PrivateFiles.with_new(output_path, fn file ->
          Ledger.transaction(fn ->
            # Serialize first enrollment before a host row exists; host locking
            # below also serializes against manual rotation/revocation.
            Ecto.Adapters.SQL.query!(
              Marshall.Repo,
              "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
              ["enrollment:" <> request.host.name],
              log: false
            )

            {host, new?} = registered_host(request, kind)
            prior = Ledger.read!(EnrollmentOperation, id: operation_id)

            credential_id =
              case prior do
                [] ->
                  credential_id = issue_or_reuse(host, request.ttl, kind, new?)

                  Ledger.create!(EnrollmentOperation, :record, %{
                    id: operation_id,
                    kind: kind,
                    request: input,
                    host_id: host.id,
                    credential_id: credential_id
                  })

                  credential_id

                [operation] ->
                  unless operation.kind == kind and operation.request == input and
                           operation.host_id == host.id,
                         do: Ledger.rollback(:operation_conflict)

                  operation.credential_id
              end

            credential = active_credential(host.id)
            unless credential.id == credential_id, do: Ledger.rollback(:credential_inactive)
            secret = Ash.load!(credential, :secret, actor: SystemActor.compute()).secret

            envelope = %{
              version: 1,
              host_id: host.id,
              credential_id: credential.id,
              credential: credential.id <> ":" <> secret,
              expires_at: DateTime.to_iso8601(credential.expires_at)
            }

            unless PrivateFiles.write_sync(file, output_path, JSON.encode!(envelope) <> "\n") ==
                     :ok,
                   do: Ledger.rollback(:credential_file_write_failed)

            {:ok, public} = Enrollment.describe(host.name)
            Map.put(public, :operation_id, operation_id)
          end)
        end)
      else
        _ -> {:error, :invalid_enrollment_request}
      end
    end)
  end

  defp registered_host(request, kind) do
    {host, new?} =
      case Ledger.read!(Host, name: request.host.name) do
        [] when kind == :prepare ->
          host = Ledger.create!(Host, :enroll, request.host)

          for pool <- request.pools,
              do: Ledger.create!(StoragePool, :enroll, Map.put(pool, :host_id, host.id))

          {host, true}

        [] ->
          Ledger.rollback(:unknown_host)

        [host] ->
          {Ledger.lock!(Host, host.id), false}
      end

    if host.maintenance_mode == :retired, do: Ledger.rollback(:host_retired)

    unless Map.take(host, Map.keys(request.host)) == request.host,
      do: Ledger.rollback(:registration_conflict)

    expected = Enum.sort_by(request.pools, & &1.name)

    actual =
      Ledger.read!(StoragePool, host_id: host.id)
      |> Enum.map(&Map.take(&1, Map.keys(hd(expected))))
      |> Enum.sort_by(& &1.name)

    unless actual == expected, do: Ledger.rollback(:registration_conflict)
    {host, new?}
  end

  defp issue_or_reuse(host, _ttl, :prepare, false), do: active_credential(host.id).id

  defp issue_or_reuse(host, ttl, _kind, _new?) do
    {:ok, issued} = Credentials.rotate(host.id, ttl)
    issued.id
  end

  defp active_credential(host_id) do
    case Ledger.read!(HostCredential, host_id: host_id) do
      [credential] ->
        unless DateTime.compare(credential.expires_at, Ledger.now()) == :gt,
          do: Ledger.rollback(:credential_inactive)

        credential

      _ ->
        Ledger.rollback(:credential_inactive)
    end
  end
end
