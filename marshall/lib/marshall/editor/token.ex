defmodule Marshall.Editor.Token do
  @moduledoc "Canonical purpose-bound editor credentials; only SHA-256 hashes persist."
  @prefixes %{
    ticket: "audi_editor_login_",
    code: "audi_editor_code_",
    cookie: "audi_editor_cookie_",
    lease: "audi_editor_stream_"
  }
  @type purpose :: :ticket | :code | :cookie | :lease

  @spec issue(purpose()) :: {String.t(), binary()}
  def issue(purpose) do
    token =
      Map.fetch!(@prefixes, purpose) <>
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {token, :crypto.hash(:sha256, token)}
  end

  @spec digest(term(), purpose()) :: {:ok, binary()} | :error
  def digest(token, purpose) when is_binary(token) and byte_size(token) <= 80 do
    with prefix when is_binary(prefix) <- Map.get(@prefixes, purpose),
         true <- byte_size(token) == byte_size(prefix) + 43 and String.starts_with?(token, prefix),
         encoded = binary_part(token, byte_size(prefix), 43),
         {:ok, bytes} when byte_size(bytes) == 32 <- Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == encoded do
      {:ok, :crypto.hash(:sha256, token)}
    else
      _ -> :error
    end
  end

  def digest(_, _), do: :error
end
