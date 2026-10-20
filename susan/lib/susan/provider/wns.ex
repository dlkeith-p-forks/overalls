defmodule Susan.Provider.WNS do
  @moduledoc """
  Windows Push Notification Services raw notifications (ADR-0236), with an
  Entra ID client-credentials token.

  A raw notification carries no display text: it activates Mila's Windows
  app, which opens the ciphertext and shows a local notification whose text
  comes from its own localized strings. The body uses the same field names
  as the FCM data message.
  """
  @behaviour Susan.Provider

  alias Susan.Provider
  alias Susan.Provider.{HTTP, Tokens}

  @impl true
  @spec deliver(Provider.message(), Susan.Config.t()) :: Provider.outcome()
  def deliver(%Provider{push_key: %{token: channel}} = message, %{wns: %{}} = config) do
    # The channel was checked at issuance; it is checked again here so a key
    # sealed under an older rule can never direct Susan elsewhere.
    if Provider.wns_channel?(channel) do
      case Tokens.wns(config) do
        {:ok, token} ->
          headers = [
            {"authorization", "Bearer " <> token},
            {"content-type", "application/octet-stream"},
            {"x-wns-type", "wns/raw"},
            {"x-wns-ttl", "3600"},
            {"x-wns-cache-policy", "cache"}
          ]

          classify(HTTP.request(:post, channel, headers, JSON.encode!(payload(message))))

        {:error, :retry} ->
          {:retry, 1}

        {:error, :unavailable} ->
          :unavailable
      end
    else
      :rejected
    end
  end

  def deliver(_message, _config), do: :unavailable

  @doc "The raw notification body: the version, kind and ciphertext only."
  @spec payload(Provider.message()) :: map()
  def payload(%Provider{kind: kind} = message) do
    %{
      "overalls_v" => "1",
      "overalls_k" => Atom.to_string(kind),
      "overalls_c" => message.ciphertext
    }
  end

  # WNS response codes: 404 and 410 mean the channel is gone; 401 an expired
  # access token; 406 and 429 throttling.
  @spec classify(HTTP.response()) :: Provider.outcome()
  def classify({:ok, 200, _headers, _body}), do: :sent
  def classify({:ok, status, _headers, _body}) when status in [404, 410], do: :unregistered

  def classify({:ok, 401, _headers, _body}) do
    Tokens.invalidate(:wns)
    {:retry, 1}
  end

  def classify({:ok, status, headers, _body}) when status in [406, 429] or status >= 500,
    do: {:retry, Provider.retry_after(headers)}

  def classify({:ok, status, _headers, _body}) when status in [400, 413], do: :rejected
  def classify({:ok, _status, _headers, _body}), do: :unavailable
  def classify({:error, :transport}), do: {:retry, 1}
end
