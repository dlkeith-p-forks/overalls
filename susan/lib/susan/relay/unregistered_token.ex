defmodule Susan.Relay.UnregisteredToken do
  @moduledoc """
  Negative cache of provider tokens that APNs or FCM reported unregistered.

  Only a keyed HMAC-SHA256 digest of provider and token is stored, so the
  database cannot reveal or enumerate device tokens. Entries expire after 30
  days; a push key whose token is cached is answered 410 without contacting
  the provider, and `/keys` refuses to issue for it.
  """
  use Ash.Resource,
    otp_app: :susan,
    domain: Susan.Relay,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "unregistered_tokens"
    repo Susan.Repo
  end

  code_interface do
    define :record, args: [:digest, :provider]
    define :lookup, args: [:digest], get?: true, not_found_error?: false
  end

  actions do
    defaults [:read]

    create :record do
      accept [:digest, :provider]
      upsert? true
      upsert_identity :digest
      upsert_fields [:recorded_at]
      change set_attribute(:recorded_at, &DateTime.utc_now/0)
    end

    read :lookup do
      argument :digest, :string, allow_nil?: false
      filter expr(digest == ^arg(:digest) and recorded_at > ago(30, :day))
    end

    destroy :expire do
      accept []
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :provider, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:apns, :fcm]]

    attribute :recorded_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  identities do
    identity :digest, [:digest]
  end
end
