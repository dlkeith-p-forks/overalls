defmodule Marshall.Ingress.Token do
  @moduledoc "Purpose-bound Audi credentials with canonical 256-bit entropy."
  @prefixes %{
    service: "audi_service_",
    session: "audi_session_",
    web_login: "audi_web_login_",
    web_code: "audi_web_code_",
    web_cookie: "audi_web_cookie_",
    web_stream: "audi_web_stream_",
    nested_stream: "audi_nested_stream_"
  }
  @type purpose ::
          :service
          | :session
          | :web_login
          | :web_code
          | :web_cookie
          | :web_stream
          | :nested_stream

  @spec issue(purpose()) :: {binary(), binary()}
  def issue(purpose \\ :service) do
    token =
      Map.fetch!(@prefixes, purpose) <>
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {token, :crypto.hash(:sha256, token)}
  end

  # @cc [owner:ghuntley,label:security] ingress-service-token-canonical
  # Credentials MUST be exactly 32 canonical random bytes under Audi's service
  # or session/browser-purpose prefix, with no interchange between purposes. Only their SHA-256
  # digest may be persisted or used in database filters.
  @spec digest(term(), purpose()) :: {:ok, binary()} | :error
  def digest(token, purpose \\ :service)

  def digest(token, purpose) when is_binary(token) and byte_size(token) <= 80 do
    with prefix when is_binary(prefix) <- Map.get(@prefixes, purpose),
         true <- byte_size(token) == byte_size(prefix) + 43 and String.starts_with?(token, prefix),
         encoded = binary_part(token, byte_size(prefix), 43),
         {:ok, bytes} when byte_size(bytes) == 32 <- Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == encoded,
         do: {:ok, :crypto.hash(:sha256, token)},
         else: (_ -> :error)
  end

  def digest(_, _), do: :error
end
