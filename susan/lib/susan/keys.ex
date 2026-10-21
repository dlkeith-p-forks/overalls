defmodule Susan.Keys do
  @moduledoc """
  `POST /api/push/v1/keys`: issues a sealed push key to the Mila app.

  The request is `{provider, token, app_id, environment, deployment}`. The
  provider token is checked for shape, the application id against the
  configured topics, and the token against the unregistered negative cache;
  nothing about the request is stored except the audit entry's key id.
  """
  require Susan.Events

  alias Susan.Audit.Log
  alias Susan.{PushKey, RateLimiter}
  alias Susan.Relay.UnregisteredToken

  @keys ~w(provider token app_id environment deployment)
  @providers %{"apns" => :apns, "fcm" => :fcm, "wns" => :wns}
  # Mila names the APNs sandbox gateway "development", as its entitlement does.
  @environments %{"production" => :production, "development" => :sandbox}

  @type response ::
          {201, map()}
          | {400 | 410 | 429 | 503, :rejected | :unregistered | :rate_limited | :unavailable,
             pos_integer() | nil}

  # @cc [owner:ghuntley,label:security;privacy] susan-key-issuance
  # Key issuance MUST accept only the closed schema, a configured application
  # id, a provider-shaped token and a DNS deployment host, MUST be rate
  # limited per source digest, MUST refuse tokens in the unregistered negative
  # cache, and MUST NOT persist the token, envelope or source address.
  @spec issue(binary(), binary(), Susan.Config.t(), integer()) :: response()
  def issue(body, source, config, now) do
    case RateLimiter.check([{:issue, source}, {:global, :all}], config.limits) do
      {:limited, scope, retry, _first} ->
        Susan.Events.emit("susan.rate_limited", scope: rate_scope(scope), retry_after: retry)
        Susan.Events.emit("susan.key_refused", reason: :rate_limited)
        {429, :rate_limited, retry}

      :ok ->
        with {:ok, fields} <- parse(body, config),
             :ok <- registered(fields, config),
             {:ok, push_key, key} <-
               PushKey.seal(config.keyring, Map.put(fields, :issued_at, now)),
             {:audit, {:ok, _}} <-
               {:audit,
                Log.append(:key_issued, :ok, %{
                  key_id: key.key_id,
                  provider: key.provider,
                  keyring_id: key.keyring_id
                })} do
          Susan.Events.emit("susan.key_issued",
            provider: key.provider,
            keyring_id: key.keyring_id
          )

          {201,
           %{
             "push_key" => push_key,
             "key_id" => key.key_id,
             "expires_at" =>
               key |> PushKey.expires_at() |> DateTime.from_unix!() |> DateTime.to_iso8601()
           }}
        else
          {:audit, :error} ->
            Susan.Events.emit("susan.key_refused", reason: :unavailable)
            {503, :unavailable, 60}

          :unregistered ->
            Susan.Events.emit("susan.key_refused", reason: :unregistered)
            {410, :unregistered, nil}

          _ ->
            Susan.Events.emit("susan.key_refused", reason: :malformed)
            {400, :rejected, nil}
        end
    end
  end

  @spec parse(binary(), Susan.Config.t()) :: {:ok, map()} | :error
  def parse(body, config) when is_binary(body) and byte_size(body) <= 1024 do
    with {:ok, %{} = value} <- JSON.decode(body),
         true <- Enum.sort(Map.keys(value)) == Enum.sort(@keys),
         {:ok, provider} <- Map.fetch(@providers, value["provider"]),
         {:ok, environment} <- Map.fetch(@environments, value["environment"]),
         true <- provider == :apns or environment == :production,
         app_id when is_binary(app_id) <- value["app_id"],
         true <- app_id in allowed(provider, config),
         token when is_binary(token) <- value["token"],
         true <- token?(provider, token),
         deployment when is_binary(deployment) <- value["deployment"],
         true <- Susan.Deployment.valid?(deployment) do
      {:ok,
       %{
         provider: provider,
         environment: environment,
         app_id: app_id,
         token: token,
         deployment: deployment
       }}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def parse(_body, _config), do: :error

  defp registered(fields, config) do
    probe = struct(PushKey, Map.merge(fields, %{key_id: nil, issued_at: 0, keyring_id: 1}))

    case UnregisteredToken.lookup!(Susan.Poke.token_digest(config, probe)) do
      nil -> :ok
      _ -> :unregistered
    end
  end

  defp allowed(:apns, config), do: config.apns_topics
  defp allowed(:fcm, config), do: config.fcm_app_ids
  defp allowed(:wns, config), do: config.wns_app_ids

  # APNs device tokens are hexadecimal; FCM registration tokens use a
  # URL-safe alphabet with a colon separator; a WNS token is the device's
  # channel URI, which names the WNS host Susan will post to.
  defp token?(:apns, token), do: Regex.match?(~r/\A(?:[0-9a-f]{2}){16,100}\z/, token)
  defp token?(:fcm, token), do: Regex.match?(~r/\A[A-Za-z0-9_:-]{32,512}\z/, token)
  defp token?(:wns, token), do: Susan.Provider.wns_channel?(token)

  defp rate_scope(:issue), do: :source
  defp rate_scope(scope), do: scope
end
