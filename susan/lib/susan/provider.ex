defmodule Susan.Provider do
  @moduledoc """
  Provider delivery for content-free pokes (ADR-0224).

  A message carries only the opaque ciphertext, the collapse id and the fixed
  kind; titles are localization keys chosen from the kind, so a caller cannot
  inject display text. APNs messages set `mutable-content` so the device's
  notification service extension decrypts; FCM messages are data-only so the
  app's messaging service decrypts.
  """

  alias Susan.PushKey

  @apns_production "https://api.push.apple.com"
  @apns_sandbox "https://api.sandbox.push.apple.com"
  @google_token "https://oauth2.googleapis.com"
  @fcm "https://fcm.googleapis.com"

  @enforce_keys [:push_key, :ciphertext, :collapse_id, :kind, :issued_at]
  defstruct @enforce_keys

  @type message :: %__MODULE__{
          push_key: PushKey.t(),
          ciphertext: String.t(),
          collapse_id: String.t(),
          kind: :needs_input,
          issued_at: non_neg_integer()
        }
  @type outcome :: :sent | :unregistered | {:retry, pos_integer()} | :rejected | :unavailable

  @callback deliver(message(), Susan.Config.t()) :: outcome()

  @spec origins() :: [String.t()]
  def origins, do: [@apns_production, @apns_sandbox, @google_token, @fcm]

  @spec apns_origin(PushKey.environment()) :: String.t()
  def apns_origin(:production), do: @apns_production
  def apns_origin(:sandbox), do: @apns_sandbox

  @spec google_token_url() :: String.t()
  def google_token_url, do: @google_token <> "/token"

  @spec fcm_origin() :: String.t()
  def fcm_origin, do: @fcm

  @spec allowed_url?(String.t()) :: boolean()
  def allowed_url?(url) when is_binary(url),
    do: Enum.any?(origins(), &String.starts_with?(url, &1 <> "/"))

  @doc "Fixed localization keys per kind: titles are never caller text."
  @spec localization(:needs_input) :: %{title: String.t(), body: String.t()}
  def localization(:needs_input),
    do: %{title: "MILA_PUSH_NEEDS_INPUT_TITLE", body: "MILA_PUSH_NEEDS_INPUT_BODY"}

  @spec deliver(message(), Susan.Config.t()) :: outcome()
  def deliver(%__MODULE__{push_key: %PushKey{provider: :apns}} = message, config),
    do: Susan.Provider.APNs.deliver(message, config)

  def deliver(%__MODULE__{push_key: %PushKey{provider: :fcm}} = message, config),
    do: Susan.Provider.FCM.deliver(message, config)

  @doc false
  @spec retry_after([Susan.Provider.HTTP.header()]) :: pos_integer()
  def retry_after(headers) do
    with {_, value} <- List.keyfind(headers, "retry-after", 0),
         {seconds, ""} when seconds > 0 <- Integer.parse(value) do
      min(seconds, 3600)
    else
      _ -> 1
    end
  end
end
