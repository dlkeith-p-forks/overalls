defmodule OverallsProtocol.SusanPoke do
  @moduledoc """
  The Susan poke request, v1 (ADR-0224, ADR-0225): Marshall's signed
  `POST /api/push/v1/poke` body.

  The body is a JSON object with exactly these members, encoded with keys in
  ascending byte order and no insignificant whitespace:

  | member        | value                                                       |
  |---------------|-------------------------------------------------------------|
  | `ciphertext`  | an `OverallsProtocol.PushPoke` v1 poke (base64url)          |
  | `collapse_id` | 22 base64url characters; opaque per install                 |
  | `delivery_id` | the Marshall delivery UUID, Susan's idempotency key         |
  | `deployment`  | the Marshall public host the push key was issued for        |
  | `issued_at`   | Unix seconds when this attempt was signed                   |
  | `kind`        | closed kind: `needs_input`                                  |
  | `nonce`       | 16 random bytes, base64url (22 characters), per attempt     |
  | `push_key`    | the opaque key Susan issued to the device (base64url)       |

  The request carries two headers:

  - `overalls-install-key`: the install's raw 32-byte Ed25519 public key,
    base64url without padding;
  - `overalls-install-signature`: the raw 64-byte Ed25519 signature,
    base64url without padding, over
    `"overalls-susan-poke-v1" || 0x00 || body`, where `body` is the exact
    request body bytes.

  Susan verifies the signature over the bytes it received, never over a
  re-encoding. `test/fixtures/susan_poke_request.json` pins one request with
  a fixed test key so both sides verify identical bytes.
  """

  alias OverallsProtocol.PushPoke

  @label "overalls-susan-poke-v1"
  @maximum_body 1024
  @key_header "overalls-install-key"
  @signature_header "overalls-install-signature"

  @type t :: %{
          ciphertext: String.t(),
          collapse_id: String.t(),
          delivery_id: String.t(),
          deployment: String.t(),
          issued_at: non_neg_integer(),
          kind: PushPoke.kind(),
          nonce: String.t(),
          push_key: String.t()
        }
  @type error :: :invalid_request | :request_too_large

  @doc "Header carrying the install public key."
  @spec key_header() :: String.t()
  def key_header, do: @key_header

  @doc "Header carrying the request signature."
  @spec signature_header() :: String.t()
  def signature_header, do: @signature_header

  @doc "Largest body Susan accepts, in bytes."
  @spec maximum_body() :: pos_integer()
  def maximum_body, do: @maximum_body

  @doc "True when `value` is a syntactically valid opaque Susan push key."
  @spec push_key?(term()) :: boolean()
  def push_key?(value) when is_binary(value) and byte_size(value) in 16..700,
    do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  def push_key?(_), do: false

  # @cc [owner:ghuntley,label:protocol;security] susan-poke-canonical-body
  # The poke body MUST contain exactly the eight v1 members with validated
  # values, in canonical key order, and MUST NOT exceed 1 KiB. It carries
  # ciphertext and opaque identifiers only: no route, title or account data.
  @doc "Encodes a validated request into its canonical body bytes."
  @spec encode(t()) :: {:ok, binary()} | {:error, error()}
  def encode(request) do
    with :ok <- validate(request) do
      members = [
        {"ciphertext", request.ciphertext},
        {"collapse_id", request.collapse_id},
        {"delivery_id", request.delivery_id},
        {"deployment", request.deployment},
        {"issued_at", request.issued_at},
        {"kind", Atom.to_string(request.kind)},
        {"nonce", request.nonce},
        {"push_key", request.push_key}
      ]

      body =
        "{" <>
          Enum.map_join(members, ",", fn {key, value} ->
            JSON.encode!(key) <> ":" <> JSON.encode!(value)
          end) <> "}"

      if byte_size(body) <= @maximum_body, do: {:ok, body}, else: {:error, :request_too_large}
    end
  end

  @doc "Decodes and validates body bytes, refusing non-canonical encodings."
  @spec decode(term()) :: {:ok, t()} | {:error, error()}
  def decode(body) when is_binary(body) and byte_size(body) <= @maximum_body do
    with {:ok, %{} = object} <- safe_decode(body),
         true <- map_size(object) == 8,
         {:ok, kind} <- kind(object["kind"]),
         request = %{
           ciphertext: object["ciphertext"],
           collapse_id: object["collapse_id"],
           delivery_id: object["delivery_id"],
           deployment: object["deployment"],
           issued_at: object["issued_at"],
           kind: kind,
           nonce: object["nonce"],
           push_key: object["push_key"]
         },
         {:ok, ^body} <- encode(request) do
      {:ok, request}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def decode(body) when is_binary(body), do: {:error, :request_too_large}
  def decode(_), do: {:error, :invalid_request}

  @doc "The exact bytes the install signature covers."
  @spec signed_message(binary()) :: binary()
  def signed_message(body) when is_binary(body), do: @label <> <<0>> <> body

  # @cc [owner:ghuntley,label:security;protocol] susan-poke-install-signature
  # Every poke MUST be signed by the install's Ed25519 identity over the domain
  # label and the exact body bytes; verification MUST use the received bytes
  # and refuse malformed keys or signatures without raising.
  @doc "Signs body bytes with a 32-byte Ed25519 seed, returning both header values."
  @spec sign(binary(), <<_::256>>) :: %{key: String.t(), signature: String.t()}
  def sign(body, <<_::binary-size(32)>> = seed) when is_binary(body) do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    signature = :crypto.sign(:eddsa, :none, signed_message(body), [seed, :ed25519])

    %{
      key: Base.url_encode64(public, padding: false),
      signature: Base.url_encode64(signature, padding: false)
    }
  end

  @doc "Verifies header values over the received body bytes."
  @spec verify(term(), term(), term()) :: :ok | {:error, :invalid_signature}
  def verify(body, key, signature)
      when is_binary(body) and is_binary(key) and is_binary(signature) do
    with {:ok, <<_::binary-size(32)>> = public} <- Base.url_decode64(key, padding: false),
         {:ok, <<_::binary-size(64)>> = raw} <- Base.url_decode64(signature, padding: false),
         true <- :crypto.verify(:eddsa, :none, signed_message(body), raw, [public, :ed25519]) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  def verify(_, _, _), do: {:error, :invalid_signature}

  @doc "The Ed25519 public key for a seed, base64url (the `overalls-install-key` value)."
  @spec public_key(<<_::256>>) :: String.t()
  def public_key(<<_::binary-size(32)>> = seed) do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    Base.url_encode64(public, padding: false)
  end

  defp validate(%{} = request) when map_size(request) == 8 do
    with %{
           ciphertext: ciphertext,
           collapse_id: collapse_id,
           delivery_id: delivery_id,
           deployment: deployment,
           issued_at: issued_at,
           kind: kind,
           nonce: nonce,
           push_key: push_key
         } <- request,
         true <- token?(ciphertext, 61, PushPoke.maximum_encoded_length()),
         true <- token?(collapse_id, 22, 22),
         true <- OverallsProtocol.uuid?(delivery_id),
         true <- OverallsProtocol.SSHHostCertificate.hostname?(deployment),
         true <- is_integer(issued_at) and issued_at in 0..4_294_967_295,
         true <- kind in [:needs_input],
         true <- token?(nonce, 22, 22),
         true <- push_key?(push_key) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate(_), do: {:error, :invalid_request}

  defp token?(value, minimum, maximum) when is_binary(value),
    do:
      byte_size(value) >= minimum and byte_size(value) <= maximum and
        Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp token?(_, _, _), do: false

  defp kind("needs_input"), do: {:ok, :needs_input}
  defp kind(_), do: :error

  defp safe_decode(body) do
    JSON.decode(body)
  rescue
    _ -> :error
  end
end
