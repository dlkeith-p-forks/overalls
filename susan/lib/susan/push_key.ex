defmodule Susan.PushKey do
  @moduledoc """
  Issued push keys: AES-256-GCM envelopes sealed with the keyring.

  A push key is `base64url(kid || iv || ciphertext || tag)`. The sealed
  plaintext binds the provider, environment, application id, deployment host,
  provider token, issue time and a random key id. Susan stores none of these:
  the envelope is the only copy, held by the device and its Marshall.

  The additional authenticated data names the format version and key id, so a
  key cannot be reinterpreted under a different keyring entry or version.
  """

  alias Susan.Keyring

  @lifetime_seconds 90 * 86_400
  @future_skew_seconds 300
  @max_encoded 700
  @aad "susan.push_key.v1"

  @enforce_keys [
    :key_id,
    :provider,
    :environment,
    :app_id,
    :deployment,
    :token,
    :issued_at,
    :keyring_id
  ]
  defstruct @enforce_keys

  @type provider :: :apns | :fcm
  @type environment :: :production | :sandbox
  @type t :: %__MODULE__{
          key_id: String.t(),
          provider: provider(),
          environment: environment(),
          app_id: String.t(),
          deployment: String.t(),
          token: String.t(),
          issued_at: non_neg_integer(),
          keyring_id: Keyring.id()
        }

  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds, do: @lifetime_seconds

  @spec max_encoded() :: pos_integer()
  def max_encoded, do: @max_encoded

  # @cc [owner:ghuntley,label:security;privacy] susan-push-key-envelope
  # A push key MUST be an AEAD envelope sealed with the active keyring entry,
  # binding provider, environment, app id, deployment, provider token, issue
  # time and key id. Susan MUST NOT persist the token or envelope. Opening MUST
  # refuse any tampered byte, unknown key id, future issue time or envelope
  # older than 90 days, with the same result shape for every refusal.
  @spec seal(Keyring.t(), map()) :: {:ok, String.t(), t()} | :error
  def seal(%Keyring{active: kid} = keyring, %{} = fields) do
    with {:ok, key} <- Keyring.fetch(keyring, kid),
         %{provider: provider, environment: environment, app_id: app_id} <- fields,
         %{deployment: deployment, token: token, issued_at: issued_at} <- fields,
         true <- provider in [:apns, :fcm] and environment in [:production, :sandbox],
         true <- is_integer(issued_at) and issued_at >= 0,
         true <- bounded?(app_id, 255) and bounded?(deployment, 253) and bounded?(token, 1024) do
      key_id = Map.get_lazy(fields, :key_id, &uuid/0)
      {:ok, raw_id} = uuid_bytes(key_id)

      plaintext =
        <<1, provider_code(provider), environment_code(environment), issued_at::64,
          raw_id::binary-16, byte_size(app_id)::8, app_id::binary, byte_size(deployment)::8,
          deployment::binary, byte_size(token)::16, token::binary>>

      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad(kid), 16, true)

      encoded =
        Base.url_encode64(<<kid, iv::binary, ciphertext::binary, tag::binary>>, padding: false)

      if byte_size(encoded) <= @max_encoded do
        {:ok, encoded,
         %__MODULE__{
           key_id: key_id,
           provider: provider,
           environment: environment,
           app_id: app_id,
           deployment: deployment,
           token: token,
           issued_at: issued_at,
           keyring_id: kid
         }}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  @spec open(Keyring.t(), term(), integer()) :: {:ok, t()} | {:error, :unknown_key | :expired_key}
  def open(%Keyring{} = keyring, encoded, now)
      when is_binary(encoded) and byte_size(encoded) <= @max_encoded and is_integer(now) do
    with {:ok, <<kid, iv::binary-12, rest::binary>>} when byte_size(rest) > 16 <-
           Base.url_decode64(encoded, padding: false),
         {:ok, key} <- Keyring.fetch(keyring, kid),
         ciphertext_size = byte_size(rest) - 16,
         <<ciphertext::binary-size(^ciphertext_size), tag::binary-16>> = rest,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad(kid), tag, false),
         {:ok, push_key} <- decode(plaintext, kid) do
      cond do
        push_key.issued_at > now + @future_skew_seconds -> {:error, :expired_key}
        now - push_key.issued_at > @lifetime_seconds -> {:error, :expired_key}
        true -> {:ok, push_key}
      end
    else
      _ -> {:error, :unknown_key}
    end
  end

  def open(_keyring, _encoded, _now), do: {:error, :unknown_key}

  @spec expires_at(t()) :: non_neg_integer()
  def expires_at(%__MODULE__{issued_at: issued_at}), do: issued_at + @lifetime_seconds

  defp decode(
         <<1, provider, environment, issued_at::64, raw_id::binary-16, app_size::8,
           app_id::binary-size(app_size), deployment_size::8,
           deployment::binary-size(deployment_size), token_size::16,
           token::binary-size(token_size)>>,
         kid
       ) do
    with {:ok, provider} <- provider_name(provider),
         {:ok, environment} <- environment_name(environment) do
      {:ok,
       %__MODULE__{
         key_id: format_uuid(raw_id),
         provider: provider,
         environment: environment,
         app_id: app_id,
         deployment: deployment,
         token: token,
         issued_at: issued_at,
         keyring_id: kid
       }}
    end
  end

  defp decode(_plaintext, _kid), do: :error

  defp aad(kid), do: @aad <> <<kid>>

  defp bounded?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp provider_code(:apns), do: 1
  defp provider_code(:fcm), do: 2
  defp provider_name(1), do: {:ok, :apns}
  defp provider_name(2), do: {:ok, :fcm}
  defp provider_name(_), do: :error
  defp environment_code(:production), do: 1
  defp environment_code(:sandbox), do: 2
  defp environment_name(1), do: {:ok, :production}
  defp environment_name(2), do: {:ok, :sandbox}
  defp environment_name(_), do: :error

  @doc false
  @spec uuid() :: String.t()
  def uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    format_uuid(<<a::48, 4::4, b::12, 2::2, c::62>>)
  end

  defp uuid_bytes(value) when is_binary(value) do
    if OverallsProtocol.uuid?(value),
      do: {:ok, value |> String.replace("-", "") |> Base.decode16!(case: :lower)},
      else: :error
  end

  defp format_uuid(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    [a, b, c, d, e] |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  defimpl Inspect do
    def inspect(key, _opts),
      do: "#Susan.PushKey<key_id: #{key.key_id}, provider: #{key.provider}, token: [redacted]>"
  end
end
