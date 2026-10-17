defmodule Marshall.SSH.Token do
  @moduledoc "Purpose-bound opaque SSH credentials; only digests are persisted."
  @prefixes %{
    gateway: "porsche_gateway_",
    session: "porsche_session_",
    approval: "porsche_approval_"
  }

  @spec issue(:gateway | :session | :approval) :: {binary(), binary()}
  def issue(purpose) do
    token =
      Map.fetch!(@prefixes, purpose) <>
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {token, :crypto.hash(:sha256, token)}
  end

  # @cc [owner:ghuntley,label:security] ssh-token-purpose-and-entropy
  # Tokens MUST contain exactly 32 canonical random bytes under the expected
  # purpose prefix. Persisted values MUST be digests, never bearer credentials.
  @spec digest(term(), :gateway | :session | :approval) :: {:ok, binary()} | :error
  def digest(value, purpose) when is_binary(value) and byte_size(value) <= 80 do
    prefix = Map.fetch!(@prefixes, purpose)
    size = byte_size(prefix)

    with <<^prefix::binary-size(^size), encoded::binary-size(43)>> <- value,
         {:ok, bytes} when byte_size(bytes) == 32 <- Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == encoded do
      {:ok, :crypto.hash(:sha256, value)}
    else
      _ -> :error
    end
  end

  def digest(_, _), do: :error
end
