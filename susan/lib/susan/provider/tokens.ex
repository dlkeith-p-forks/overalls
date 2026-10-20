defmodule Susan.Provider.Tokens do
  @moduledoc """
  Caches provider credentials in memory: the APNs provider JWT (refreshed
  after 40 minutes, inside Apple's one-hour limit) and the FCM and WNS OAuth
  access tokens (refreshed five minutes before expiry). None is logged or
  stored.
  """
  use GenServer

  alias Susan.Provider.JWT

  @apns_lifetime 2_400
  @fcm_scope "https://www.googleapis.com/auth/firebase.messaging"
  @wns_scope "https://wns.windows.com/.default"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(options, :name, __MODULE__))

  @spec apns(Susan.Config.t()) :: {:ok, String.t()} | :error
  def apns(config), do: GenServer.call(__MODULE__, {:apns, config})

  @spec fcm(Susan.Config.t()) :: {:ok, String.t()} | {:error, :retry | :unavailable}
  def fcm(config), do: GenServer.call(__MODULE__, {:fcm, config}, 20_000)

  @spec wns(Susan.Config.t()) :: {:ok, String.t()} | {:error, :retry | :unavailable}
  def wns(config), do: GenServer.call(__MODULE__, {:wns, config}, 20_000)

  @spec invalidate(:apns | :fcm | :wns) :: :ok
  def invalidate(provider), do: GenServer.cast(__MODULE__, {:invalidate, provider})

  @impl true
  def init(:ok), do: {:ok, %{apns: nil, fcm: nil, wns: nil}}

  @impl true
  def handle_call({:apns, config}, _from, state) do
    now = System.os_time(:second)

    case state.apns do
      {token, issued} when now - issued < @apns_lifetime ->
        {:reply, {:ok, token}, state}

      _ ->
        case config.apns do
          %{key: key, key_id: key_id, team_id: team_id} ->
            token = JWT.es256(%{"kid" => key_id}, %{"iss" => team_id, "iat" => now}, key)
            {:reply, {:ok, token}, %{state | apns: {token, now}}}

          _ ->
            {:reply, :error, state}
        end
    end
  end

  def handle_call({:fcm, config}, _from, state), do: oauth(:fcm, &exchange(config.fcm, &1), state)
  def handle_call({:wns, config}, _from, state), do: oauth(:wns, &entra(config.wns, &1), state)

  @impl true
  def handle_cast({:invalidate, provider}, state), do: {:noreply, Map.put(state, provider, nil)}

  defp oauth(provider, fetch, state) do
    now = System.os_time(:second)

    case Map.fetch!(state, provider) do
      {token, expires} when expires - now > 300 ->
        {:reply, {:ok, token}, state}

      _ ->
        case fetch.(now) do
          {:ok, token, expires} ->
            {:reply, {:ok, token}, Map.put(state, provider, {token, expires})}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp exchange(%{client_email: email, private_key: key}, now) do
    url = Susan.Provider.google_token_url()

    assertion =
      JWT.rs256(
        %{},
        %{"iss" => email, "scope" => @fcm_scope, "aud" => url, "iat" => now, "exp" => now + 3600},
        key
      )

    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => assertion
      })

    token_response(url, body, now)
  end

  defp exchange(_missing, _now), do: {:error, :unavailable}

  # Entra ID client credentials for WNS: the tenant, client id and secret come
  # from Susan's credentials; the token endpoint's origin is fixed.
  defp entra(%{tenant_id: tenant, client_id: client, client_secret: secret}, now) do
    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => client,
        "client_secret" => secret,
        "scope" => @wns_scope
      })

    token_response(Susan.Provider.microsoft_token_url(tenant), body, now)
  end

  defp entra(_missing, _now), do: {:error, :unavailable}

  defp token_response(url, body, now) do
    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Susan.Provider.HTTP.request(:post, url, headers, body) do
      {:ok, 200, _headers, response} ->
        with {:ok, %{"access_token" => token, "expires_in" => lifetime}} <- JSON.decode(response),
             true <- is_binary(token) and byte_size(token) in 1..4096,
             true <- is_integer(lifetime) and lifetime > 0 do
          {:ok, token, now + lifetime}
        else
          _ -> {:error, :unavailable}
        end

      {:ok, status, _headers, _body} when status in [429] or status >= 500 ->
        {:error, :retry}

      {:ok, _status, _headers, _body} ->
        {:error, :unavailable}

      {:error, :transport} ->
        {:error, :retry}
    end
  end
end
