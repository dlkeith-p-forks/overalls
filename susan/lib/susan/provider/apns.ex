defmodule Susan.Provider.APNs do
  @moduledoc """
  APNs HTTP/2 provider API with token (`.p8`) authentication.

  The alert names fixed localization keys and sets `mutable-content`, so the
  Mila notification service extension replaces it with text decrypted from
  the `overalls` ciphertext. Susan never sees or sends display text.
  """
  @behaviour Susan.Provider

  alias Susan.Provider
  alias Susan.Provider.{HTTP, Tokens}

  @impl true
  @spec deliver(Provider.message(), Susan.Config.t()) :: Provider.outcome()
  def deliver(%Provider{push_key: key} = message, config) do
    case Tokens.apns(config) do
      {:ok, jwt} ->
        url = Provider.apns_origin(key.environment) <> "/3/device/" <> key.token

        headers = [
          {"authorization", "bearer " <> jwt},
          {"apns-topic", key.app_id},
          {"apns-push-type", "alert"},
          {"apns-priority", "10"},
          {"apns-collapse-id", message.collapse_id},
          {"apns-expiration", Integer.to_string(message.issued_at + 3600)},
          {"content-type", "application/json"}
        ]

        classify(HTTP.request(:post, url, headers, JSON.encode!(payload(message))))

      :error ->
        :unavailable
    end
  end

  @doc "The APNs JSON payload: fixed loc-keys, mutable-content and the opaque ciphertext."
  @spec payload(Provider.message()) :: map()
  def payload(%Provider{kind: kind} = message) do
    keys = Provider.localization(kind)

    %{
      "aps" => %{
        "alert" => %{"title-loc-key" => keys.title, "loc-key" => keys.body},
        "mutable-content" => 1,
        "sound" => "default",
        "thread-id" => Atom.to_string(kind)
      },
      "overalls" => %{"v" => 1, "k" => Atom.to_string(kind), "c" => message.ciphertext}
    }
  end

  @spec classify(HTTP.response()) :: Provider.outcome()
  def classify({:ok, 200, _headers, _body}), do: :sent
  def classify({:ok, 410, _headers, _body}), do: :unregistered

  def classify({:ok, 400, _headers, body}) do
    case reason(body) do
      reason when reason in ["BadDeviceToken", "DeviceTokenNotForTopic"] -> :unregistered
      _ -> :rejected
    end
  end

  def classify({:ok, 403, _headers, body}) do
    if reason(body) in ["ExpiredProviderToken", "InvalidProviderToken"] do
      Tokens.invalidate(:apns)
      {:retry, 1}
    else
      :unavailable
    end
  end

  def classify({:ok, status, headers, _body}) when status == 429 or status >= 500,
    do: {:retry, Provider.retry_after(headers)}

  def classify({:ok, 413, _headers, _body}), do: :rejected
  def classify({:ok, _status, _headers, _body}), do: :unavailable
  def classify({:error, :transport}), do: {:retry, 1}

  defp reason(body) do
    case JSON.decode(body) do
      {:ok, %{"reason" => reason}} when is_binary(reason) -> reason
      _ -> nil
    end
  end
end
