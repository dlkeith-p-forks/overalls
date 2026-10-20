defmodule Marshall.Scim.Oidc.IdToken do
  @moduledoc """
  Pure OpenID Connect ID-token verification against a provider JWKS.

  Only compact JWS tokens signed with an allowlisted asymmetric algorithm are
  accepted. Every segment MUST be canonical unpadded base64url so that any
  textual change to a token changes the bytes that are verified. Claims are
  checked for exact issuer, audience/authorized party, expiry, issue time and
  nonce before a `Marshall.Scim.Oidc.VerifiedClaims` value is returned.
  """

  alias Marshall.Scim.Oidc.VerifiedClaims

  @algorithms %{"RS256" => "RSA", "ES256" => "EC"}
  @max_token_bytes 16_384
  @default_skew 60

  @type jwks :: [JOSE.JWK.t()]
  @type expected :: %{
          required(:issuer) => String.t(),
          required(:client_id) => String.t(),
          required(:nonce) => String.t(),
          required(:now) => integer(),
          optional(:skew) => non_neg_integer()
        }
  @type error ::
          :malformed_id_token
          | :unsupported_algorithm
          | :no_matching_key
          | :invalid_signature
          | :issuer_mismatch
          | :audience_mismatch
          | :expired
          | :issued_in_future
          | :nonce_mismatch
          | :invalid_subject

  # @cc [owner:ghuntley,label:security] scim-oidc-id-token-verification
  # An ID token MUST be accepted only with a valid RS256/ES256 signature from a
  # provider JWKS key, canonical base64url segments, an exact issuer, an audience
  # containing the client, a current expiry/issue time and the session nonce.
  @spec verify(String.t(), jwks(), expected()) :: {:ok, VerifiedClaims.t()} | {:error, error()}
  def verify(token, jwks, expected)
      when is_binary(token) and is_list(jwks) and is_map(expected) do
    with {:ok, header, payload} <- split(token),
         {:ok, alg} <- algorithm(header),
         {:ok, keys} <- candidate_keys(jwks, alg, header),
         :ok <- verify_signature(keys, alg, token),
         {:ok, claims} <- decode_object(payload) do
      validate_claims(claims, expected)
    end
  end

  def verify(_, _, _), do: {:error, :malformed_id_token}

  @doc "Parses a JWKS document into JOSE keys, ignoring keys that cannot sign."
  @spec parse_jwks(term()) :: {:ok, jwks()} | {:error, :invalid_jwks}
  def parse_jwks(%{"keys" => keys}) when is_list(keys) do
    parsed =
      Enum.flat_map(keys, fn
        %{"kty" => kty} = key when kty in ["RSA", "EC"] ->
          if Map.get(key, "use", "sig") == "sig" and not Map.has_key?(key, "d") do
            from_map(key)
          else
            []
          end

        _ ->
          []
      end)

    if parsed == [], do: {:error, :invalid_jwks}, else: {:ok, parsed}
  end

  def parse_jwks(_), do: {:error, :invalid_jwks}

  @spec from_map(map()) :: [JOSE.JWK.t()]
  defp from_map(key) do
    [JOSE.JWK.from_map(key)]
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @spec split(String.t()) :: {:ok, map(), binary()} | {:error, :malformed_id_token}
  defp split(token) when byte_size(token) > @max_token_bytes, do: {:error, :malformed_id_token}

  defp split(token) do
    with [header, payload, signature] <- String.split(token, "."),
         {:ok, header_json} <- canonical_decode(header),
         {:ok, payload_json} <- canonical_decode(payload),
         {:ok, signature_bytes} <- canonical_decode(signature),
         true <- signature_bytes != "",
         {:ok, header_map} <- decode_object(header_json) do
      {:ok, header_map, payload_json}
    else
      _ -> {:error, :malformed_id_token}
    end
  end

  @spec canonical_decode(binary()) :: {:ok, binary()} | :error
  defp canonical_decode(segment) do
    with {:ok, decoded} <- Base.url_decode64(segment, padding: false),
         true <- Base.url_encode64(decoded, padding: false) == segment do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  @spec decode_object(binary()) :: {:ok, map()} | {:error, :malformed_id_token}
  defp decode_object(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :malformed_id_token}
    end
  end

  @spec algorithm(map()) :: {:ok, String.t()} | {:error, error()}
  defp algorithm(%{"crit" => _}), do: {:error, :unsupported_algorithm}

  defp algorithm(%{"alg" => alg}) when is_map_key(@algorithms, alg), do: {:ok, alg}
  defp algorithm(_), do: {:error, :unsupported_algorithm}

  @spec candidate_keys(jwks(), String.t(), map()) :: {:ok, jwks()} | {:error, :no_matching_key}
  defp candidate_keys(jwks, alg, header) do
    kty = Map.fetch!(@algorithms, alg)
    kid = Map.get(header, "kid")

    keys =
      Enum.filter(jwks, fn jwk ->
        {_, map} = JOSE.JWK.to_map(jwk)

        map["kty"] == kty and Map.get(map, "alg", alg) == alg and
          (is_nil(kid) or map["kid"] == kid)
      end)

    if keys == [], do: {:error, :no_matching_key}, else: {:ok, keys}
  end

  @spec verify_signature(jwks(), String.t(), String.t()) :: :ok | {:error, :invalid_signature}
  defp verify_signature(keys, alg, token) do
    if Enum.any?(keys, &signature_valid?(&1, alg, token)),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  @spec signature_valid?(JOSE.JWK.t(), String.t(), String.t()) :: boolean()
  defp signature_valid?(jwk, alg, token) do
    match?({true, _, _}, JOSE.JWS.verify_strict(jwk, [alg], token))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @spec validate_claims(map(), expected()) :: {:ok, VerifiedClaims.t()} | {:error, error()}
  defp validate_claims(claims, expected) do
    skew = Map.get(expected, :skew, @default_skew)
    now = expected.now

    with :ok <- check(claims["iss"] == expected.issuer, :issuer_mismatch),
         :ok <- audience(claims, expected.client_id),
         :ok <- check(integer?(claims["exp"]) and claims["exp"] > now - skew, :expired),
         :ok <- check(integer?(claims["iat"]) and claims["iat"] <= now + skew, :issued_in_future),
         :ok <- nonce(claims["nonce"], expected.nonce),
         :ok <- subject(claims["sub"]) do
      {:ok,
       %VerifiedClaims{
         issuer: claims["iss"],
         subject: claims["sub"],
         expires_at: claims["exp"]
       }}
    end
  end

  @spec audience(map(), String.t()) :: :ok | {:error, :audience_mismatch}
  defp audience(%{"aud" => aud} = claims, client_id) when is_binary(aud),
    do: audience(Map.put(claims, "aud", [aud]), client_id)

  defp audience(%{"aud" => [_ | _] = aud} = claims, client_id) do
    azp = Map.get(claims, "azp")

    cond do
      not Enum.all?(aud, &is_binary/1) -> {:error, :audience_mismatch}
      client_id not in aud -> {:error, :audience_mismatch}
      length(aud) > 1 and azp != client_id -> {:error, :audience_mismatch}
      not is_nil(azp) and azp != client_id -> {:error, :audience_mismatch}
      true -> :ok
    end
  end

  defp audience(_, _), do: {:error, :audience_mismatch}

  @spec nonce(term(), String.t()) :: :ok | {:error, :nonce_mismatch}
  defp nonce(actual, expected)
       when is_binary(actual) and is_binary(expected) and expected != "" and
              byte_size(actual) == byte_size(expected) do
    check(Plug.Crypto.secure_compare(actual, expected), :nonce_mismatch)
  end

  defp nonce(_, _), do: {:error, :nonce_mismatch}

  @spec subject(term()) :: :ok | {:error, :invalid_subject}
  defp subject(sub) when is_binary(sub) and byte_size(sub) in 1..255, do: :ok
  defp subject(_), do: {:error, :invalid_subject}

  @spec integer?(term()) :: boolean()
  defp integer?(value), do: is_integer(value)

  @spec check(boolean(), error()) :: :ok | {:error, error()}
  defp check(true, _), do: :ok
  defp check(false, error), do: {:error, error}
end
