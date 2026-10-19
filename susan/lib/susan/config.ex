defmodule Susan.Config do
  @moduledoc """
  Closed startup configuration.

  Public settings come from the JSON file named by `SUSAN_CONFIG_FILE`:

      {"version": 1, "bind": "127.0.0.1", "port": 4100,
       "trusted_proxies": ["127.0.0.1"],
       "apns_topics": ["dev.overalls.mila"], "fcm_app_ids": ["dev.overalls.mila"]}

  Secrets come only from files in `$CREDENTIALS_DIRECTORY`, named after the
  SOPS keys of `secrets/overalls-susan.enc.json`: `APNS_KEY_P8`,
  `APNS_KEY_ID`, `APNS_TEAM_ID`, `FCM_SERVICE_ACCOUNT_JSON`,
  `SUSAN_PUSH_KEY_SIGNING_KEY` and `DATABASE_URL`. Every file passes the
  `Susan.Credentials` custody checks. Any failure is the single fixed error
  `:invalid_runtime_configuration`.
  """

  import Bitwise
  alias Susan.{Credentials, Keyring}

  @fields ~w(version bind port trusted_proxies apns_topics fcm_app_ids limits)
  @limit_scopes %{
    "key" => :key,
    "install" => :install,
    "source" => :source,
    "global" => :global,
    "issue" => :issue
  }

  @enforce_keys [
    :bind,
    :port,
    :trusted_proxies,
    :apns_topics,
    :fcm_app_ids,
    :apns,
    :fcm,
    :keyring,
    :repo,
    :limits
  ]
  defstruct @enforce_keys

  @type apns :: %{key: tuple(), key_id: String.t(), team_id: String.t()}
  @type fcm :: %{project_id: String.t(), client_email: String.t(), private_key: tuple()}
  @type t :: %__MODULE__{
          bind: :inet.ip_address(),
          port: 1..65_535,
          trusted_proxies: [:inet.ip_address()],
          apns_topics: [String.t()],
          fcm_app_ids: [String.t()],
          apns: apns() | nil,
          fcm: fcm() | nil,
          keyring: Keyring.t(),
          repo: keyword(),
          limits: Susan.RateLimiter.limits()
        }

  # @cc [owner:ghuntley,label:security] susan-configuration-secret-custody
  # Startup MUST reject unknown fields, invalid listeners, application ids or
  # limits, and any secret that fails credential custody or parsing. Secrets
  # MUST come only from $CREDENTIALS_DIRECTORY files, never the environment or
  # the public configuration file. Errors MUST be one fixed value without
  # contents, paths or parser exceptions.
  @spec load(term(), term()) :: {:ok, t()} | {:error, :invalid_runtime_configuration}
  def load(path, credentials) do
    with {:ok, encoded} <- Credentials.read(path, :config, 16_384),
         {:ok, %{"version" => 1} = value} <- JSON.decode(encoded),
         true <- Map.keys(value) -- @fields == [],
         {:ok, bind} <- address(Map.get(value, "bind", "127.0.0.1")),
         port = Map.get(value, "port", 4100),
         true <- is_integer(port) and port in 1..65_535,
         {:ok, proxies} <- addresses(Map.get(value, "trusted_proxies", [])),
         {:ok, topics} <- app_ids(Map.get(value, "apns_topics", [])),
         {:ok, fcm_ids} <- app_ids(Map.get(value, "fcm_app_ids", [])),
         true <- topics != [] or fcm_ids != [],
         {:ok, limits} <- limits(Map.get(value, "limits", %{})),
         true <- Credentials.canonical_path?(credentials),
         {:ok, keyring} <-
           secret(credentials, "SUSAN_PUSH_KEY_SIGNING_KEY", 8192, &Keyring.parse/1),
         {:ok, repo} <- secret(credentials, "DATABASE_URL", 2048, &repo/1),
         {:ok, apns} <- optional(topics, fn -> apns(credentials) end),
         {:ok, fcm} <- optional(fcm_ids, fn -> fcm(credentials) end) do
      {:ok,
       %__MODULE__{
         bind: bind,
         port: port,
         trusted_proxies: proxies,
         apns_topics: topics,
         fcm_app_ids: fcm_ids,
         apns: apns,
         fcm: fcm,
         keyring: keyring,
         repo: repo,
         limits: limits
       }}
    else
      _ -> {:error, :invalid_runtime_configuration}
    end
  rescue
    _ -> {:error, :invalid_runtime_configuration}
  end

  defp optional([], _load), do: {:ok, nil}
  defp optional(_ids, load), do: load.()

  defp secret(directory, name, maximum, parse) do
    with {:ok, bytes} <- Credentials.secret(directory, name, maximum),
         {:ok, value} <- parse.(Credentials.chomp(bytes)) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp apns(directory) do
    with {:ok, key} <- secret(directory, "APNS_KEY_P8", 4096, &ec_key/1),
         {:ok, key_id} <- secret(directory, "APNS_KEY_ID", 64, &identifier/1),
         {:ok, team_id} <- secret(directory, "APNS_TEAM_ID", 64, &identifier/1) do
      {:ok, %{key: key, key_id: key_id, team_id: team_id}}
    end
  end

  defp fcm(directory),
    do: secret(directory, "FCM_SERVICE_ACCOUNT_JSON", 16_384, &service_account/1)

  # @cc [owner:ghuntley,label:security] susan-fcm-fixed-token-origin
  # A service account MUST name Google's fixed token endpoint; a document
  # pointing token exchange anywhere else MUST be refused at startup.
  defp service_account(encoded) do
    with {:ok, %{"type" => "service_account"} = account} <- JSON.decode(encoded),
         %{"project_id" => project, "client_email" => email, "private_key" => pem} <- account,
         true <-
           Map.get(account, "token_uri", Susan.Provider.google_token_url()) ==
             Susan.Provider.google_token_url(),
         true <-
           is_binary(project) and Regex.match?(~r/\A[a-z][a-z0-9-]{4,61}[a-z0-9]\z/, project),
         true <- is_binary(email) and Regex.match?(~r/\A[^@\s]{1,128}@[a-z0-9.-]{1,128}\z/, email),
         {:ok, key} <- rsa_key(pem) do
      {:ok, %{project_id: project, client_email: email, private_key: key}}
    else
      _ -> :error
    end
  end

  defp ec_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry] ->
        case :public_key.pem_entry_decode(entry) do
          {:ECPrivateKey, _, _, {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}, _, _} = key ->
            {:ok, key}

          _ ->
            :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp rsa_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry] ->
        case :public_key.pem_entry_decode(entry) do
          {:RSAPrivateKey, _, modulus, _, _, _, _, _, _, _, _} = key
          when modulus >= 1 <<< 2047 ->
            {:ok, key}

          _ ->
            :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp rsa_key(_), do: :error

  defp identifier(value) do
    if Regex.match?(~r/\A[A-Z0-9]{10}\z/, value), do: {:ok, value}, else: :error
  end

  defp repo(url) do
    with %URI{scheme: scheme} = uri when scheme in ["postgres", "postgresql", "ecto"] <-
           URI.parse(url),
         true <- is_binary(uri.path) and Regex.match?(~r/\A\/[a-z_][a-z0-9_]{0,62}\z/, uri.path),
         options when is_list(options) <- Ecto.Repo.Supervisor.parse_url(url) do
      {:ok, options}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp address(value) when is_binary(value) and byte_size(value) <= 45 do
    with {:ok, parsed} <- :inet.parse_strict_address(String.to_charlist(value)),
         true <- to_string(:inet.ntoa(parsed)) == value do
      {:ok, parsed}
    else
      _ -> :error
    end
  end

  defp address(_), do: :error

  defp addresses(values) when is_list(values) and length(values) <= 16 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case address(value) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp addresses(_), do: :error

  defp app_ids(values) when is_list(values) and length(values) <= 8 do
    if Enum.all?(
         values,
         &(is_binary(&1) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9.-]{0,154}\z/, &1))
       ),
       do: {:ok, Enum.uniq(values)},
       else: :error
  end

  defp app_ids(_), do: :error

  defp limits(%{} = values) do
    Enum.reduce_while(values, {:ok, Susan.RateLimiter.defaults()}, fn
      {scope, %{"burst" => burst, "per_hour" => rate} = limit}, {:ok, acc}
      when is_map_key(@limit_scopes, scope) and map_size(limit) == 2 and is_integer(burst) and
             burst in 1..100_000 and is_integer(rate) and rate in 1..10_000_000 ->
        {:cont,
         {:ok, Map.put(acc, Map.fetch!(@limit_scopes, scope), %{burst: burst, per_hour: rate})}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp limits(_), do: :error

  defimpl Inspect do
    def inspect(config, _opts),
      do:
        "#Susan.Config<port: #{config.port}, apns: #{config.apns != nil}, fcm: #{config.fcm != nil}, secrets: [redacted]>"
  end
end
