defmodule Susan.Provider.JWT do
  @moduledoc "Compact JWS signing for provider credentials (ES256 for APNs, RS256 for Google)."

  @type ec_key :: tuple()
  @type rsa_key :: tuple()

  @spec es256(map(), map(), ec_key()) :: String.t()
  def es256(header, claims, key) do
    input = signing_input(Map.put(header, "alg", "ES256"), claims)
    der = :public_key.sign(input, :sha256, key)
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> Base.url_encode64(<<r::256, s::256>>, padding: false)
  end

  @spec rs256(map(), map(), rsa_key()) :: String.t()
  def rs256(header, claims, key) do
    input = signing_input(Map.put(header, "alg", "RS256"), claims)
    input <> "." <> Base.url_encode64(:public_key.sign(input, :sha256, key), padding: false)
  end

  defp signing_input(header, claims) do
    Base.url_encode64(JSON.encode!(Map.put(header, "typ", "JWT")), padding: false) <>
      "." <> Base.url_encode64(JSON.encode!(claims), padding: false)
  end
end
