defmodule Susan.Provider do
  @moduledoc """
  Provider delivery for content-free pokes (ADR-0224).

  A message carries only the opaque ciphertext, the collapse id and the fixed
  kind; titles are localization keys chosen from the kind, so a caller cannot
  inject display text. APNs messages set `mutable-content` so the device's
  notification service extension decrypts; FCM messages are data-only so the
  app's messaging service decrypts; WNS messages are raw notifications that
  activate the Windows app, which decrypts (ADR-0236).

  WNS is the one provider whose host is chosen per device: its token is the
  device's channel URI on a `*.notify.windows.com` host. Such a URI is
  accepted at key issuance only in the exact shape `wns_channel?/1` allows,
  is sealed inside the push key, and is checked again before every send, so
  no poke-time value selects an origin.
  """

  alias Susan.PushKey

  @apns_production "https://api.push.apple.com"
  @apns_sandbox "https://api.sandbox.push.apple.com"
  @google_token "https://oauth2.googleapis.com"
  @fcm "https://fcm.googleapis.com"
  @microsoft_token "https://login.microsoftonline.com"
  @wns_suffix ".notify.windows.com"

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
  def origins, do: [@apns_production, @apns_sandbox, @google_token, @fcm, @microsoft_token]

  @spec apns_origin(PushKey.environment()) :: String.t()
  def apns_origin(:production), do: @apns_production
  def apns_origin(:sandbox), do: @apns_sandbox

  @spec google_token_url() :: String.t()
  def google_token_url, do: @google_token <> "/token"

  @spec fcm_origin() :: String.t()
  def fcm_origin, do: @fcm

  @doc "The Entra ID token endpoint for [tenant], a UUID from the WNS credentials."
  @spec microsoft_token_url(String.t()) :: String.t()
  def microsoft_token_url(tenant), do: @microsoft_token <> "/" <> tenant <> "/oauth2/v2.0/token"

  # @cc [owner:ghuntley,label:security;privacy] susan-wns-channel-shape
  # A WNS channel URI MUST be HTTPS on port 443 to a lower-case DNS host under
  # `.notify.windows.com`, with a path, no userinfo and no fragment, and at
  # most 1024 bytes. Anything else MUST be refused at issuance and before a
  # send, so a push key can only ever direct Susan to WNS.
  @doc "Whether [uri] is a WNS channel URI Susan may post to."
  @spec wns_channel?(term()) :: boolean()
  def wns_channel?(uri) when is_binary(uri) and byte_size(uri) <= 1024 do
    case URI.new(uri) do
      {:ok,
       %URI{scheme: "https", userinfo: nil, fragment: nil, host: host, port: 443, path: "/" <> _}}
      when is_binary(host) ->
        String.ends_with?(host, @wns_suffix) and
          Regex.match?(
            ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\z/,
            host
          ) and
          not String.contains?(uri, ["\\", " ", "%00"]) and
          String.starts_with?(uri, "https://" <> host <> "/")

      _ ->
        false
    end
  end

  def wns_channel?(_uri), do: false

  @spec allowed_url?(String.t()) :: boolean()
  def allowed_url?(url) when is_binary(url),
    do: Enum.any?(origins(), &String.starts_with?(url, &1 <> "/")) or wns_channel?(url)

  @doc "Fixed localization keys per kind: titles are never caller text."
  @spec localization(:needs_input) :: %{title: String.t(), body: String.t()}
  def localization(:needs_input),
    do: %{title: "MILA_PUSH_NEEDS_INPUT_TITLE", body: "MILA_PUSH_NEEDS_INPUT_BODY"}

  @spec deliver(message(), Susan.Config.t()) :: outcome()
  def deliver(%__MODULE__{push_key: %PushKey{provider: :apns}} = message, config),
    do: Susan.Provider.APNs.deliver(message, config)

  def deliver(%__MODULE__{push_key: %PushKey{provider: :fcm}} = message, config),
    do: Susan.Provider.FCM.deliver(message, config)

  def deliver(%__MODULE__{push_key: %PushKey{provider: :wns}} = message, config),
    do: Susan.Provider.WNS.deliver(message, config)

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
