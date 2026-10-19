defmodule Susan.Provider.Tokens do
  @moduledoc """
  Caches provider credentials in memory: the APNs provider JWT (refreshed
  after 40 minutes, inside Apple's one-hour limit) and the FCM OAuth access
  token (refreshed five minutes before expiry). Neither is logged or stored.
  """
  use GenServer

  alias Susan.Provider.JWT

  @apns_lifetime 2_400
  @fcm_scope "https://www.googleapis.com/auth/firebase.messaging"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(options, :name, __MODULE__))

  @spec apns(Susan.Config.t()) :: {:ok, String.t()} | :error
  def apns(config), do: GenServer.call(__MODULE__, {:apns, config})

  @spec fcm(Susan.Config.t()) :: {:ok, String.t()} | {:error, :retry | :unavailable}
  def fcm(config), do: GenServer.call(__MODULE__, {:fcm, config}, 20_000)

  @spec invalidate(:apns | :fcm) :: :ok
  def invalidate(provider), do: GenServer.cast(__MODULE__, {:invalidate, provider})

  @impl true
  def init(:ok), do: {:ok, %{apns: nil, fcm: nil}}

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

  def handle_call({:fcm, config}, _from, state) do
    now = System.os_time(:second)

    case state.fcm do
      {token, expires} when expires - now > 300 ->
        {:reply, {:ok, token}, state}

      _ ->
        case exchange(config.fcm, now) do
          {:ok, token, expires} -> {:reply, {:ok, token}, %{state | fcm: {token, expires}}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_cast({:invalidate, provider}, state), do: {:noreply, Map.put(state, provider, nil)}

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

  defp exchange(_missing, _now), do: {:error, :unavailable}
end
