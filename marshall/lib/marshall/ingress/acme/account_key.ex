defmodule Marshall.Ingress.ACME.AccountKey do
  @moduledoc "P-256 ACME account key and RFC 7638 public identity; no persistence policy."
  @derive {Inspect, only: [:thumbprint]}
  @enforce_keys [:private, :public, :jwk, :thumbprint]
  defstruct [:private, :public, :jwk, :thumbprint]
  @type t :: %__MODULE__{private: binary(), public: binary(), jwk: map(), thumbprint: binary()}
  @order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  @spec generate() :: t()
  def generate do
    {_public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    {:ok, key} = from_private(private)
    key
  end

  # @cc [owner:ghuntley,label:security;protocol] acme-account-key-identity
  # Public identity MUST be derived from a valid P-256 scalar, never supplied
  # independently. Thumbprints MUST hash exactly the RFC 7638 required public
  # members in lexicographic order. Inspection and errors MUST omit the scalar.
  @spec from_private(term()) :: {:ok, t()} | {:error, :invalid_account_key}
  def from_private(<<scalar::256>> = private) when scalar > 0 and scalar < @order do
    {<<4, x::binary-size(32), y::binary-size(32)>> = public, _} =
      :crypto.generate_key(:ecdh, :secp256r1, private)

    x = Base.url_encode64(x, padding: false)
    y = Base.url_encode64(y, padding: false)
    canonical = ~s({"crv":"P-256","kty":"EC","x":"#{x}","y":"#{y}"})
    thumbprint = :crypto.hash(:sha256, canonical) |> Base.url_encode64(padding: false)

    {:ok,
     %__MODULE__{
       private: private,
       public: public,
       jwk: %{"crv" => "P-256", "kty" => "EC", "x" => x, "y" => y},
       thumbprint: thumbprint
     }}
  rescue
    _ -> {:error, :invalid_account_key}
  end

  def from_private(_), do: {:error, :invalid_account_key}
end
