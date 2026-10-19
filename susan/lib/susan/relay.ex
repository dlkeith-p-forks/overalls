defmodule Susan.Relay do
  @moduledoc """
  Susan's relay domain (ADR-0224): install identities, the key-id deny-list,
  the negative cache of provider-unregistered tokens and delivery receipts.

  No resource stores a provider token, push key, ciphertext, route or source
  address. Tokens appear only as keyed HMAC digests in the negative cache.
  """
  use Ash.Domain, otp_app: :susan

  resources do
    resource Susan.Relay.InstallIdentity
    resource Susan.Relay.KeyDenial
    resource Susan.Relay.UnregisteredToken
    resource Susan.Relay.DeliveryReceipt
  end
end
