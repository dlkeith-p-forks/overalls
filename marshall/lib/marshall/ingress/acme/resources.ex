defmodule Marshall.Ingress.ACME.Resources do
  @moduledoc "Validate issuer representations against the single fleet wildcard."
  alias Marshall.Ingress.ACME.JWS

  # @cc [owner:ghuntley,label:security;protocol] acme-resource-identity
  # Accepted orders MUST contain exactly the requested wildcard DNS identifier.
  # Authorization representations MUST bind the expected base name
  # and wildcard flag, with at most one supported DNS-01 challenge. Resource URLs
  # MUST stay at the trusted issuer origin; unexpected status or shape MUST fail.
  @spec order(map(), term(), binary()) :: {:ok, map()} | {:error, :invalid_acme_resource}
  def order(client, value, host) do
    with %{
           "status" => status,
           "identifiers" => identifiers,
           "authorizations" => auths,
           "finalize" => finalize
         } <- value,
         true <- status in ["pending", "ready", "processing", "valid", "invalid"],
         true <- identifiers?(identifiers, host),
         true <- is_list(auths) and length(auths) == 1,
         true <- Enum.all?([finalize | auths], &url?(client, &1)),
         certificate = Map.get(value, "certificate"),
         true <- (is_nil(certificate) and status != "valid") or url?(client, certificate) do
      {:ok,
       %{
         status: status,
         authorizations: auths,
         finalize: finalize,
         certificate: certificate,
         hostname: host
       }}
    else
      _ -> {:error, :invalid_acme_resource}
    end
  end

  @spec authorization(map(), term(), binary(), boolean()) ::
          {:ok, map()} | {:error, :invalid_acme_resource}
  def authorization(client, value, host, wildcard) do
    with %{
           "identifier" => %{"type" => "dns", "value" => ^host},
           "status" => status,
           "challenges" => challenges
         } <- value,
         true <- is_boolean(wildcard) and Map.get(value, "wildcard", false) == wildcard,
         true <- status in ["pending", "valid", "invalid", "deactivated", "expired", "revoked"],
         true <- is_list(challenges) and length(challenges) <= 16,
         [%{"type" => "dns-01", "url" => url, "token" => token, "status" => challenge_status}] <-
           Enum.filter(challenges, &(is_map(&1) and Map.get(&1, "type") == "dns-01")),
         true <- url?(client, url),
         true <- challenge_status in ["pending", "processing", "valid", "invalid"],
         true <- is_binary(token) and byte_size(token) in 22..256 and String.valid?(token),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, token) do
      {:ok,
       %{
         status: status,
         hostname: host,
         wildcard: wildcard,
         challenge: %{url: url, token: token, status: challenge_status}
       }}
    else
      _ -> {:error, :invalid_acme_resource}
    end
  end

  @spec url?(map(), term()) :: boolean()
  def url?(client, url) do
    if JWS.https_url?(url) do
      uri = URI.parse(url)
      {uri.scheme, String.downcase(uri.host), uri.port} == client.origin
    else
      false
    end
  end

  defp identifiers?(values, host) when is_list(values) and length(values) == 1 do
    values == [%{"type" => "dns", "value" => "*." <> host}]
  end

  defp identifiers?(_, _), do: false
end
