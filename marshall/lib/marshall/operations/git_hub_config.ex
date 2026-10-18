defmodule Marshall.Operations.GitHubConfig do
  @moduledoc "Validated optional GitHub OAuth deployment settings; credential bytes stay in files."

  @type settings :: [
          {:github_client_id, String.t()}
          | {:github_client_secret_file, String.t()}
          | {:github_redirect_uri, String.t()}
        ]
  @type options :: [allow_loopback: boolean()]

  # @cc [owner:ghuntley,label:security] github-configuration-complete-or-disabled
  # Missing GitHub settings MUST disable the connection ceremony. Partial or
  # malformed settings MUST fail with a fixed error without reflecting input.
  # The redirect MUST use the fixed callback path, without query, fragment or
  # userinfo. Plain HTTP is permitted only for explicitly enabled loopback tests
  # and development. Credential bytes MUST NOT enter application configuration.
  @spec from_env(%{optional(String.t()) => String.t()}, options()) ::
          {:ok, settings() | nil} | {:error, :invalid_github_configuration}
  def from_env(env, options \\ []) do
    values =
      Enum.map(
        ~w(MARSHALL_GITHUB_CLIENT_ID MARSHALL_GITHUB_CLIENT_SECRET_FILE MARSHALL_GITHUB_REDIRECT_URI),
        &Map.get(env, &1)
      )

    case values do
      [nil, nil, nil] ->
        {:ok, nil}

      [client_id, secret_file, redirect_uri]
      when is_binary(client_id) and is_binary(secret_file) and is_binary(redirect_uri) ->
        if valid_client_id?(client_id) and valid_secret_file?(secret_file) and
             valid_redirect?(redirect_uri, Keyword.get(options, :allow_loopback, false)) do
          {:ok,
           github_client_id: client_id,
           github_client_secret_file: secret_file,
           github_redirect_uri: redirect_uri}
        else
          {:error, :invalid_github_configuration}
        end

      _ ->
        {:error, :invalid_github_configuration}
    end
  end

  @spec valid_client_id?(String.t()) :: boolean()
  defp valid_client_id?(value), do: Regex.match?(~r/\A[A-Za-z0-9_.-]{1,200}\z/, value)

  @spec valid_secret_file?(String.t()) :: boolean()
  defp valid_secret_file?(value) do
    byte_size(value) in 1..4096 and Path.type(value) == :absolute and
      not String.contains?(value, ["\0", "\n", "\r"])
  end

  @spec valid_redirect?(String.t(), boolean()) :: boolean()
  defp valid_redirect?(value, allow_loopback) do
    with true <- byte_size(value) <= 4096,
         {:ok, uri} <- URI.new(value),
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- uri.path == "/auth/github-com/callback" do
      uri.scheme == "https" or
        (allow_loopback and uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"])
    else
      _ -> false
    end
  end
end
