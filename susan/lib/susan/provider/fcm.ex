defmodule Susan.Provider.FCM do
  @moduledoc """
  FCM HTTP v1 with a service-account OAuth token.

  Messages are data-only: Mila's messaging service decrypts the ciphertext and
  posts a local notification whose text comes from the fixed localization key.
  """
  @behaviour Susan.Provider

  alias Susan.Provider
  alias Susan.Provider.{HTTP, Tokens}

  @impl true
  @spec deliver(Provider.message(), Susan.Config.t()) :: Provider.outcome()
  def deliver(%Provider{} = message, %{fcm: %{project_id: project}} = config) do
    case Tokens.fcm(config) do
      {:ok, token} ->
        url = Provider.fcm_origin() <> "/v1/projects/" <> project <> "/messages:send"

        headers = [
          {"authorization", "Bearer " <> token},
          {"content-type", "application/json"}
        ]

        classify(HTTP.request(:post, url, headers, JSON.encode!(payload(message))))

      {:error, :retry} ->
        {:retry, 1}

      {:error, :unavailable} ->
        :unavailable
    end
  end

  def deliver(_message, _config), do: :unavailable

  @doc "The FCM v1 message: data-only, high priority, collapsed and bounded to one hour."
  @spec payload(Provider.message()) :: map()
  def payload(%Provider{push_key: key, kind: kind} = message) do
    keys = Provider.localization(kind)

    %{
      "message" => %{
        "token" => key.token,
        "data" => %{
          "overalls_v" => "1",
          "overalls_k" => Atom.to_string(kind),
          "overalls_c" => message.ciphertext,
          "overalls_title_loc_key" => keys.title,
          "overalls_body_loc_key" => keys.body
        },
        "android" => %{
          "priority" => "high",
          "collapse_key" => message.collapse_id,
          "ttl" => "3600s"
        }
      }
    }
  end

  @spec classify(HTTP.response()) :: Provider.outcome()
  def classify({:ok, 200, _headers, _body}), do: :sent
  def classify({:ok, 404, _headers, _body}), do: :unregistered

  def classify({:ok, 403, _headers, body}) do
    if String.contains?(body, "SENDER_ID_MISMATCH"), do: :unregistered, else: :unavailable
  end

  def classify({:ok, 400, _headers, body}) do
    if String.contains?(body, "UNREGISTERED"), do: :unregistered, else: :rejected
  end

  def classify({:ok, 401, _headers, _body}) do
    Tokens.invalidate(:fcm)
    {:retry, 1}
  end

  def classify({:ok, status, headers, _body}) when status == 429 or status >= 500,
    do: {:retry, Provider.retry_after(headers)}

  def classify({:ok, _status, _headers, _body}), do: :unavailable
  def classify({:error, :transport}), do: {:retry, 1}
end
