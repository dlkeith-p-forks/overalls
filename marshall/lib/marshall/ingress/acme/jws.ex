defmodule Marshall.Ingress.ACME.JWS do
  @moduledoc "Bounded RFC 8555 flattened ES256 requests and DNS-01 proof derivation."
  alias Marshall.Ingress.ACME.AccountKey

  # @cc [owner:ghuntley,label:security;protocol] acme-signed-request-binding
  # Signatures MUST bind the exact HTTPS URL, nonce, payload and exactly one of
  # account kid or public jwk in the protected header. ES256 signatures MUST use
  # fixed-width R||S, not DER. POST-as-GET MUST have an empty encoded payload.
  # Caller-supplied headers/algorithms MUST NOT override these fields. Nonce
  # single-use ownership and issuer URL trust belong to the transport caller.
  @spec sign(AccountKey.t(), term(), term(), term(), term()) ::
          {:ok, binary()} | {:error, :invalid_acme_request}
  def sign(%AccountKey{} = key, url, nonce, identity, payload) do
    with true <- https_url?(url),
         true <- encoded?(nonce),
         {:ok, identity} <- identity(key, identity),
         {:ok, payload} <- payload(payload) do
      protected = Map.merge(identity, %{"alg" => "ES256", "url" => url, "nonce" => nonce})
      protected = protected |> Jason.encode!() |> encode()
      payload = encode(payload)
      der = :crypto.sign(:ecdsa, :sha256, protected <> "." <> payload, [key.private, :secp256r1])
      {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)

      {:ok,
       Jason.encode!(%{
         protected: protected,
         payload: payload,
         signature: encode(<<r::256, s::256>>)
       })}
    else
      _ -> {:error, :invalid_acme_request}
    end
  rescue
    _ -> {:error, :invalid_acme_request}
  end

  def sign(_, _, _, _, _), do: {:error, :invalid_acme_request}

  # @cc [owner:ghuntley,label:protocol] acme-dns-proof-binding
  # DNS-01 values MUST hash token + dot + account JWK thumbprint with SHA-256
  # and encode without padding. Invalid token syntax MUST produce no proof.
  @spec dns_proof(AccountKey.t(), term()) :: {:ok, binary()} | {:error, :invalid_acme_token}
  def dns_proof(%AccountKey{} = key, token) do
    if is_binary(token) and byte_size(token) in 22..256 and String.valid?(token) and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, token) do
      {:ok, :crypto.hash(:sha256, token <> "." <> key.thumbprint) |> encode()}
    else
      {:error, :invalid_acme_token}
    end
  end

  def dns_proof(_, _), do: {:error, :invalid_acme_token}

  # @cc [owner:ghuntley,label:security] acme-ipv4-origin
  # ACME URLs MUST reject IPv6 literals, including scoped and mapped forms.
  # Hostname transport resolution remains IPv4-only at the transport boundary.
  @spec https_url?(term()) :: boolean()
  def https_url?(value) when is_binary(value) and byte_size(value) in 1..2048 do
    with true <- String.valid?(value) and Regex.match?(~r/\A[\x21-\x7e]+\z/, value),
         {:ok, uri} <- URI.new(value) do
      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
        not String.contains?(uri.host, ":") and
        is_nil(uri.userinfo) and is_nil(uri.fragment) and uri.port in 1..65_535
    else
      _ -> false
    end
  end

  def https_url?(_), do: false

  defp identity(key, :new_account), do: {:ok, %{"jwk" => key.jwk}}

  defp identity(_, {:account, kid}) do
    if https_url?(kid), do: {:ok, %{"kid" => kid}}, else: :error
  end

  defp identity(_, _), do: :error

  defp payload(:post_as_get), do: {:ok, ""}

  defp payload(value) when is_map(value) and map_size(value) <= 32 do
    with {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= 16_384,
         do: {:ok, encoded},
         else: (_ -> :error)
  end

  defp payload(_), do: :error

  defp encoded?(value) when is_binary(value) and byte_size(value) in 1..256 do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> encode(bytes) == value
      _ -> false
    end
  end

  defp encoded?(_), do: false
  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
