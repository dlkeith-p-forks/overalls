defmodule Marshall.Scim.Oidc.Provider do
  @moduledoc """
  HTTP interactions with the configured OpenID Connect provider.

  Discovery is read from `<issuer>/.well-known/openid-configuration`; the
  advertised issuer MUST equal the configured issuer and every endpoint MUST be
  HTTPS. Requests use `Req` with redirects and retries disabled. Tests inject a
  plug through `config :marshall, Marshall.Scim.Oidc, req_options: [...]`.
  Response bodies, codes and tokens are never logged.
  """

  alias Marshall.Scim.Oidc.IdToken

  @type metadata :: %{
          issuer: String.t(),
          authorization_endpoint: String.t(),
          token_endpoint: String.t(),
          jwks_uri: String.t(),
          token_auth: :client_secret_basic | :client_secret_post
        }
  @type error :: :provider_unavailable | :invalid_provider_metadata | :token_exchange_failed

  @spec discover(String.t()) :: {:ok, metadata()} | {:error, error()}
  def discover(issuer) when is_binary(issuer) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    with {:ok, body} <- get_json(url) do
      metadata(body, issuer)
    end
  end

  @spec jwks(metadata()) :: {:ok, IdToken.jwks()} | {:error, error()}
  def jwks(%{jwks_uri: uri}) do
    with {:ok, body} <- get_json(uri),
         {:ok, keys} <- IdToken.parse_jwks(body) do
      {:ok, keys}
    else
      {:error, :invalid_jwks} -> {:error, :invalid_provider_metadata}
      {:error, _} = error -> error
    end
  end

  @doc "Exchanges an authorization code (with its PKCE verifier) for an ID token."
  @spec exchange_code(metadata(), map()) :: {:ok, String.t()} | {:error, error()}
  def exchange_code(metadata, %{
        code: code,
        verifier: verifier,
        redirect_uri: redirect_uri,
        client_id: client_id,
        client_secret: client_secret
      }) do
    form = [
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      code_verifier: verifier,
      client_id: client_id
    ]

    {form, auth} =
      case metadata.token_auth do
        :client_secret_post ->
          {form ++ [client_secret: client_secret], []}

        :client_secret_basic ->
          credentials =
            URI.encode_www_form(client_id) <> ":" <> URI.encode_www_form(client_secret)

          {form, [auth: {:basic, credentials}]}
      end

    request =
      [url: metadata.token_endpoint, form: form, headers: [accept: "application/json"]] ++ auth

    case Req.post(req(request)) do
      {:ok, %Req.Response{status: 200, body: %{"id_token" => id_token}}}
      when is_binary(id_token) ->
        {:ok, id_token}

      {:ok, %Req.Response{}} ->
        {:error, :token_exchange_failed}

      {:error, _} ->
        {:error, :provider_unavailable}
    end
  end

  @spec get_json(String.t()) :: {:ok, map()} | {:error, error()}
  defp get_json(url) do
    case Req.get(req(url: url, headers: [accept: "application/json"])) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: 200}} -> {:error, :invalid_provider_metadata}
      {:ok, %Req.Response{}} -> {:error, :provider_unavailable}
      {:error, _} -> {:error, :provider_unavailable}
    end
  end

  @spec req(keyword()) :: Req.Request.t()
  defp req(options) do
    [redirect: false, retry: false, receive_timeout: 10_000, connect_options: [timeout: 5_000]]
    |> Keyword.merge(options)
    |> Keyword.merge(injected_options())
    |> Req.new()
  end

  @spec injected_options() :: keyword()
  defp injected_options do
    :marshall
    |> Application.get_env(Marshall.Scim.Oidc, [])
    |> Keyword.get(:req_options, [])
  end

  @spec metadata(map(), String.t()) :: {:ok, metadata()} | {:error, :invalid_provider_metadata}
  defp metadata(body, issuer) do
    with true <- body["issuer"] == issuer,
         {:ok, authorize} <- https(body["authorization_endpoint"]),
         {:ok, token} <- https(body["token_endpoint"]),
         {:ok, jwks} <- https(body["jwks_uri"]),
         {:ok, token_auth} <- token_auth(body["token_endpoint_auth_methods_supported"]) do
      {:ok,
       %{
         issuer: issuer,
         authorization_endpoint: authorize,
         token_endpoint: token,
         jwks_uri: jwks,
         token_auth: token_auth
       }}
    else
      _ -> {:error, :invalid_provider_metadata}
    end
  end

  @spec token_auth(term()) :: {:ok, :client_secret_basic | :client_secret_post} | :error
  defp token_auth(nil), do: {:ok, :client_secret_basic}

  defp token_auth(methods) when is_list(methods) do
    cond do
      "client_secret_basic" in methods -> {:ok, :client_secret_basic}
      "client_secret_post" in methods -> {:ok, :client_secret_post}
      true -> :error
    end
  end

  defp token_auth(_), do: :error

  @spec https(term()) :: {:ok, String.t()} | :error
  defp https(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        {:ok, value}

      _ ->
        :error
    end
  end

  defp https(_), do: :error
end
