defmodule Marshall.Galileo.GitHub do
  @moduledoc "Built-in GitHub admission from trusted VM execution identity."
  alias Marshall.Compute.Ledger
  alias Marshall.Galileo.Authorizations
  alias OverallsProtocol.GitHub, as: Wire

  # @cc [owner:ghuntley,label:security] github-broker-owner-identity
  # Only a freshly admitted VM binding may select its persisted owner's GitHub
  # identity. Guest headers, routes and shared writers MUST NOT select another
  # account. Generic integration attachments retain their independent policy.
  @spec authorize(String.t(), term()) :: {:ok, map()} | {:error, atom()}
  def authorize(token, %{"binding" => binding, "route" => route} = request)
      when map_size(request) == 2 do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(binding),
         {:ok, route} <- Wire.route(route) do
      Ledger.transaction(fn ->
        vm = Authorizations.admit_execution!(token, binding)

        case Marshall.GitHub.authorization(vm.owner_id, vm.id) do
          {:ok, %{token: token} = credential} ->
            response(
              route,
              credential_headers(route.kind, token),
              %{
                "kind" => "connected",
                "id" => credential.lease_id,
                "connection_id" => credential.id,
                "generation" => credential.generation
              },
              credential.ttl
            )

          {:ok, :anonymous} ->
            response(route, [], %{"kind" => "anonymous"}, 2000)

          {:error, reason} when reason in [:unavailable, :temporarily_unavailable] ->
            Ledger.rollback(:unavailable)

          {:error, _} ->
            Ledger.rollback(:unauthorized)
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def authorize(_, _), do: {:error, :invalid_request}

  # @cc [owner:ghuntley,label:security] github-broker-renewal-generation
  # Every renewal MUST repeat execution admission and the exact connected lease
  # generation or anonymous exclusion check, returning TTL only. It MUST NOT
  # read a provider token or create another request lease.
  @spec renew(String.t(), term()) :: {:ok, map()} | {:error, atom()}
  def renew(token, %{"binding" => binding, "lease" => lease} = request)
      when map_size(request) == 2 do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(binding),
         {:ok, lease} <- Wire.lease(lease) do
      Ledger.transaction(fn ->
        vm = Authorizations.admit_execution!(token, binding)

        result =
          case lease do
            :anonymous ->
              Marshall.GitHub.renew_anonymous(vm.owner_id, vm.id)

            lease ->
              Marshall.GitHub.renew(
                vm.owner_id,
                vm.id,
                lease.id,
                lease.connection_id,
                lease.generation
              )
          end

        case result do
          {:ok, %{ttl: ttl}} -> %{"version" => 1, "ttl" => ttl}
          {:error, _} -> Ledger.rollback(:unauthorized)
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def renew(_, _), do: {:error, :invalid_request}

  @spec close(String.t(), term()) :: {:ok, map()} | {:error, atom()}
  def close(token, %{"binding" => binding, "lease" => lease} = request)
      when map_size(request) == 2 do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(binding),
         {:ok, lease} <- Wire.lease(lease) do
      Ledger.transaction(fn ->
        vm = Authorizations.admit_execution!(token, binding)

        case lease do
          :anonymous -> :ok
          lease -> Marshall.GitHub.close_lease(vm.owner_id, vm.id, lease.id)
        end

        %{"closed" => true}
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def close(_, _), do: {:error, :invalid_request}

  # @cc [owner:ghuntley,label:security] github-broker-origin-authentication
  # Smart HTTP Git and Gist requests MUST use GitHub's token-as-password Basic
  # authentication; API and content requests use Bearer authentication. Opaque
  # capabilities MUST NOT receive the owner's OAuth credential.
  @spec credential_headers(Wire.kind(), String.t()) :: [[String.t()]]
  defp credential_headers(:capability, _token), do: []

  defp credential_headers(kind, token) when kind in [:git, :gist],
    do: [["authorization", "Basic " <> Base.encode64("x-access-token:" <> token)]]

  defp credential_headers(_kind, token), do: [["authorization", "Bearer " <> token]]

  @spec response(Wire.route(), [[String.t()]], map(), pos_integer()) :: map()
  defp response(route, headers, lease, ttl) do
    headers = if route.kind == :capability, do: [], else: headers

    response = %{
      "target" => Wire.origin(route.kind),
      "strip_prefix" => nil,
      "headers" => headers,
      "ttl" => ttl,
      "lease" => lease
    }

    case Wire.authorization(response) do
      {:ok, _} -> response
      _ -> Ledger.rollback(:invalid_request)
    end
  end
end
