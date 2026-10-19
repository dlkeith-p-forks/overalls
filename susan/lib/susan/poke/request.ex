defmodule Susan.Poke.Request do
  @moduledoc """
  Strict decoding of a signed `POST /api/push/v1/poke` request.

  The wire format is `OverallsProtocol.SusanPoke`, shared with Marshall's
  sender: a canonical JSON object with exactly the keys `ciphertext`,
  `collapse_id`, `delivery_id`, `deployment`, `issued_at`, `kind`, `nonce` and
  `push_key` in ascending order. The `overalls-install-key` header carries
  base64url (no padding) of the raw 32-byte Ed25519 public key;
  `overalls-install-signature` carries base64url (no padding) of the Ed25519
  signature over `"overalls-susan-poke-v1" || 0x00 || body`, verified over the
  received bytes.
  """

  alias OverallsProtocol.SusanPoke

  @max_body 1024
  @kinds %{"needs_input" => :needs_input}

  @enforce_keys [
    :push_key,
    :deployment,
    :ciphertext,
    :kind,
    :collapse_id,
    :delivery_id,
    :nonce,
    :issued_at,
    :install_key,
    :signature,
    :body
  ]
  defstruct @enforce_keys

  @type kind :: :needs_input
  @type t :: %__MODULE__{
          push_key: String.t(),
          deployment: String.t(),
          ciphertext: String.t(),
          kind: kind(),
          collapse_id: String.t(),
          delivery_id: String.t(),
          nonce: <<_::128>>,
          issued_at: non_neg_integer(),
          install_key: <<_::256>>,
          signature: <<_::512>>,
          body: binary()
        }

  @spec max_body() :: pos_integer()
  def max_body, do: @max_body

  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@kinds)

  # @cc [owner:ghuntley,label:security;protocol] susan-poke-strict-schema
  # A poke MUST be at most 1 KiB and decode through OverallsProtocol.SusanPoke:
  # exactly the documented keys in canonical order and types, kind from the
  # closed enum, a canonical UUID delivery id, a 16-byte nonce and a base64url
  # ciphertext. Unknown keys, non-canonical encodings or oversized fields MUST
  # be refused without raising or creating atoms.
  @spec parse(term(), term(), term()) :: {:ok, t()} | :error
  def parse(body, install_key, signature)
      when is_binary(body) and byte_size(body) <= @max_body do
    with {:ok, request} <- SusanPoke.decode(body),
         true <- base64url?(request.push_key, Susan.PushKey.max_encoded()),
         true <- Susan.Deployment.valid?(request.deployment),
         {:ok, <<_::128>> = nonce} <- decode64(request.nonce, 22),
         {:ok, <<_::256>> = install_key} <- decode64(install_key, 43),
         {:ok, <<_::512>> = signature} <- decode64(signature, 86) do
      {:ok,
       %__MODULE__{
         push_key: request.push_key,
         deployment: request.deployment,
         ciphertext: request.ciphertext,
         kind: request.kind,
         collapse_id: request.collapse_id,
         delivery_id: request.delivery_id,
         nonce: nonce,
         issued_at: request.issued_at,
         install_key: install_key,
         signature: signature,
         body: body
       }}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def parse(_body, _install_key, _signature), do: :error

  @doc "Lower-case hex SHA-256 of the raw install public key."
  @spec fingerprint(<<_::256>>) :: String.t()
  def fingerprint(<<_::256>> = key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  @doc "Verifies the Ed25519 install signature over the domain label and exact body bytes."
  @spec signed?(t()) :: boolean()
  def signed?(%__MODULE__{body: body, signature: signature, install_key: key}) do
    :crypto.verify(:eddsa, :none, SusanPoke.signed_message(body), signature, [key, :ed25519])
  rescue
    _ -> false
  end

  defp base64url?(value, maximum),
    do:
      is_binary(value) and byte_size(value) in 1..maximum and
        Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp decode64(value, maximum) do
    if base64url?(value, maximum),
      do: Base.url_decode64(value, padding: false),
      else: :error
  end
end
