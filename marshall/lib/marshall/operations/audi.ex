defmodule Marshall.Operations.Audi do
  @moduledoc "Trusted Audi service enrollment; only public metadata leaves the command."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.{Service, Token}
  alias Marshall.Operations.{PrivateFiles, Privacy}
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;recovery] audi-dns-private-custody
  # DNS enrollment MUST exclusively reserve a private output before changing
  # authority and sync the token before transaction commit. Output failures roll
  # back authority and retain the file. Neither the credential nor its digest may
  # enter command output.
  @spec rotate_dns(String.t(), Path.t()) :: {:ok, map()} | {:error, atom()}
  def rotate_dns(name, output) do
    enroll(%{name: name, role: :dns, host_id: nil, addresses: []}, output)
  end

  # @cc [owner:ghuntley,label:security;recovery] audi-gateway-private-custody
  # Gateway enrollment MUST exclusively reserve a private output before changing
  # authority, accept only canonical IPv4 literals bound to one existing host, and
  # sync the token before transaction commit. Output failures roll back authority
  # and retain the file. Neither the credential nor its digest may enter output.
  @spec rotate_gateway(String.t(), String.t(), String.t(), Path.t()) ::
          {:ok, map()} | {:error, atom()}
  def rotate_gateway(name, host, addresses, output) do
    with {:ok, list} <- parse_addresses(addresses),
         :ok <- validate_uuid(host) do
      enroll(%{name: name, role: :gateway, host_id: host, addresses: list}, output)
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  @spec verify(Path.t()) :: {:ok, map()} | {:error, atom()}
  def verify(path) do
    Privacy.run(fn ->
      with {:ok, token} <- PrivateFiles.read(path),
           {:ok, service} <-
             Marshall.Ingress.service_identity(%{token: token}, actor: SystemActor.compute()) do
        {:ok, Map.put(public(service), :verified, true)}
      else
        _ -> {:error, :audi_credential_failed}
      end
    end)
  end

  @spec revoke(String.t()) :: {:ok, map()} | {:error, atom()}
  def revoke(name) do
    Privacy.run(fn ->
      Ledger.transaction(fn ->
        case Ledger.read!(Service, name: name) do
          [] ->
            Ledger.rollback(:service_not_found)

          [service | _] ->
            case Marshall.Ingress.disable_service(%{id: service.id},
                   actor: SystemActor.compute()
                 ) do
              {:ok, disabled} -> public(disabled)
              _ -> Ledger.rollback(:audi_disable_failed)
            end
        end
      end)
      |> disabled_result()
    end)
  end

  defp enroll(request, output) do
    Privacy.run(fn ->
      PrivateFiles.with_new(output, fn file ->
        Ledger.transaction(fn ->
          {token, _hash} = Token.issue(:service)

          with :ok <- PrivateFiles.write_sync(file, output, token),
               {:ok, service} <-
                 Marshall.Ingress.configure_service(Map.put(request, :token, token),
                   actor: SystemActor.compute()
                 ) do
            public(service)
          else
            _ -> Ledger.rollback(:audi_enrollment_failed)
          end
        end)
      end)
      |> configured_result()
    end)
  end

  defp public(service),
    do: Map.take(service, [:id, :name, :role, :host_id, :generation, :enabled])

  defp configured_result({:ok, value} = ok) when is_map(value) do
    Marshall.Events.emit("ingress.service_configured",
      service_id: value.id,
      host_id: Map.get(value, :host_id)
    )

    ok
  end

  defp configured_result({:error, reason})
       when reason in [:unsafe_output_path, :output_exists, :output_create_failed],
       do: {:error, reason}

  defp configured_result(_), do: {:error, :audi_operation_failed}

  defp disabled_result({:ok, value} = ok) when is_map(value) do
    Marshall.Events.emit("ingress.service_disabled",
      service_id: value.id,
      host_id: Map.get(value, :host_id)
    )

    ok
  end

  defp disabled_result(_), do: {:error, :audi_operation_failed}

  @spec parse_addresses(binary()) :: {:ok, [String.t()]} | :error
  defp parse_addresses(""), do: {:ok, []}

  defp parse_addresses(value) when is_binary(value) do
    parts = String.split(value, ",")

    if parts != [] and length(parts) <= 8 and Enum.uniq(parts) == parts and
         Enum.all?(parts, &canonical_ipv4?/1),
       do: {:ok, parts},
       else: :error
  end

  defp parse_addresses(_), do: :error

  defp validate_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_arguments}
    end
  end

  defp validate_uuid(_), do: {:error, :invalid_arguments}

  defp canonical_ipv4?(value) when is_binary(value) do
    case :inet.parse_ipv4strict_address(String.to_charlist(value)) do
      {:ok, ip} -> List.to_string(:inet.ntoa(ip)) == value
      _ -> false
    end
  end
end
