defmodule Marshall.GitHub.Provider do
  @moduledoc "Fixed-origin GitHub OAuth transport. Responses and errors never escape as diagnostics."
  alias Marshall.GitHub.Grant
  require Marshall.Events

  @scopes ~w(repo workflow read:org project gist notifications read:user user:email read:packages write:packages offline_access)
  @type identity :: %{id: pos_integer(), login: binary()}
  @type error :: :unavailable | :invalid_response | :unauthorized
  @type token_parameters :: %{
          optional(:code) => binary(),
          optional(:code_verifier) => binary(),
          optional(:redirect_uri) => binary(),
          optional(:grant_type) => binary(),
          optional(:refresh_token) => binary()
        }
  @callback exchange(binary(), binary()) :: {:ok, Grant.t()} | {:error, error()}
  @callback refresh(binary()) :: {:ok, Grant.t()} | {:error, error()}
  @callback identity(binary()) :: {:ok, identity()} | {:error, error()}
  @callback revoke(binary()) :: :ok | {:error, error()}
  @callback revoke_token(binary()) :: :ok | {:error, error()}

  @spec scopes() :: [binary()]
  def scopes, do: @scopes

  @doc "GitHub omits offline_access and normalizes narrower scopes under granted parents."
  @spec sufficient_scopes?([binary()]) :: boolean()
  def sufficient_scopes?(scopes) do
    implications = %{
      "user" => ["read:user", "user:email"],
      "write:org" => ["read:org"],
      "admin:org" => ["read:org"],
      "write:packages" => ["read:packages"]
    }

    effective = Enum.flat_map(scopes, fn scope -> [scope | Map.get(implications, scope, [])] end)
    Enum.all?(@scopes -- ["offline_access"], &(&1 in effective))
  end

  @spec authorization_url(binary(), binary()) :: binary()
  def authorization_url(state, challenge) do
    "https://github.com/login/oauth/authorize?" <>
      URI.encode_query(%{
        client_id: Application.fetch_env!(:marshall, :github_client_id),
        redirect_uri: Application.fetch_env!(:marshall, :github_redirect_uri),
        scope: Enum.join(@scopes, " "),
        state: state,
        code_challenge: challenge,
        code_challenge_method: "S256"
      })
  end

  # @cc [owner:ghuntley,label:security] github-provider-fixed-origin
  # Tokens and client secrets MUST travel only in fixed HTTPS-origin request
  # bodies or authorization headers. Automatic retries and redirects MUST remain
  # disabled, and raw response bodies/errors MUST NOT be returned to callers.
  @spec exchange(binary(), binary()) :: {:ok, Grant.t()} | {:error, error()}
  def exchange(code, verifier) do
    token_request(%{
      code: code,
      code_verifier: verifier,
      redirect_uri: Application.fetch_env!(:marshall, :github_redirect_uri)
    })
  end

  @spec refresh(binary()) :: {:ok, Grant.t()} | {:error, error()}
  def refresh(token), do: token_request(%{grant_type: "refresh_token", refresh_token: token})

  @spec identity(binary()) :: {:ok, identity()} | {:error, error()}
  def identity(token) do
    with {:ok, %{status: 200, body: body}} <-
           request(
             method: :get,
             url: "https://api.github.com/user",
             headers: [{"authorization", "Bearer " <> token}]
           ),
         {:ok, %{"id" => id, "login" => login}} <- decode(body),
         true <- is_integer(id) and id > 0 and is_binary(login) and byte_size(login) in 1..100 do
      {:ok, %{id: id, login: login}}
    else
      {:ok, %{status: status}} when status in [401, 403] -> {:error, :unauthorized}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @spec revoke(binary()) :: :ok | {:error, error()}
  def revoke(token) do
    result = revoke_at(token, "grant")

    Marshall.Events.emit("github.token_revoked",
      kind: :grant,
      outcome: if(result == :ok, do: :ok, else: :error)
    )

    result
  end

  @spec revoke_token(binary()) :: :ok | {:error, error()}
  def revoke_token(token) do
    result = revoke_at(token, "token")

    Marshall.Events.emit("github.token_revoked",
      kind: :token,
      outcome: if(result == :ok, do: :ok, else: :error)
    )

    result
  end

  defp revoke_at(token, endpoint) do
    result =
      with {:ok, secret} <- secret(),
           id when is_binary(id) <- Application.get_env(:marshall, :github_client_id),
           {:ok, %{status: status}} <-
             request(
               method: :delete,
               url: "https://api.github.com/applications/" <> URI.encode(id) <> "/" <> endpoint,
               auth: {:basic, id <> ":" <> secret},
               json: %{access_token: token}
             ),
           true <- status in [204, 404] do
        :ok
      else
        _ -> {:error, :unavailable}
      end

    result
  rescue
    _ -> {:error, :unavailable}
  end

  # @cc [owner:ghuntley,label:security;protocol] github-provider-rotating-bearer-grant
  # Provider token responses MUST explicitly identify bearer authority and supply
  # the complete bounded rotating pair. Missing or other token types, nonexpiring
  # grants and provider error bodies MUST NOT establish usable credentials.
  @spec token_request(token_parameters()) :: {:ok, Grant.t()} | {:error, error()}
  defp token_request(parameters) do
    with {:ok, secret} <- secret(),
         id when is_binary(id) <- Application.get_env(:marshall, :github_client_id),
         {:ok, %{status: 200, body: body}} <-
           request(
             method: :post,
             url: "https://github.com/login/oauth/access_token",
             form: Map.merge(parameters, %{client_id: id, client_secret: secret})
           ),
         {:ok, %{"token_type" => "bearer"} = decoded} <- decode(body) do
      Grant.decode(decoded)
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp request(options) do
    headers =
      Keyword.get(options, :headers, []) ++
        [
          {"accept", "application/json"},
          {"user-agent", "Overalls-GitHub"},
          {"x-github-api-version", "2022-11-28"}
        ]

    options
    |> Keyword.put(:headers, headers)
    |> Keyword.merge(
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: 10_000,
      connect_options: [timeout: 5_000]
    )
    |> Req.request()
  end

  defp decode(body) when is_binary(body) and byte_size(body) <= 65_536, do: Jason.decode(body)
  defp decode(_), do: {:error, :invalid_response}

  defp secret do
    with path when is_binary(path) <- Application.get_env(:marshall, :github_client_secret_file),
         {:ok, value} <- File.read(path),
         true <- byte_size(value) in 1..8192,
         value = String.trim_trailing(value),
         true <- byte_size(value) > 0 do
      {:ok, value}
    else
      _ -> {:error, :unavailable}
    end
  end
end
