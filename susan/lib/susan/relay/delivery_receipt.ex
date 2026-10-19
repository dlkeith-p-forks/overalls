defmodule Susan.Relay.DeliveryReceipt do
  @moduledoc """
  At-most-once delivery receipts keyed by install fingerprint and Marshall's
  delivery id, retained for 24 hours.

  A claim inserts `sending` under a unique index; a concurrent duplicate loses
  the insert and is answered 429. A `sent` or `unregistered` receipt answers a
  retried poke without contacting the provider again, so Marshall retries never
  double-notify. A `failed` receipt, or a `sending` claim older than 60 seconds
  (a crashed attempt), may be reclaimed.
  """
  use Ash.Resource,
    otp_app: :susan,
    domain: Susan.Relay,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "delivery_receipts"
    repo Susan.Repo

    custom_indexes do
      index [:inserted_at]
    end
  end

  code_interface do
    define :claim, args: [:install_fingerprint, :delivery_id]
    define :find, args: [:install_fingerprint, :delivery_id], get?: true, not_found_error?: false
    define :finish, args: [:status]
  end

  actions do
    defaults [:read]

    create :claim do
      accept [:install_fingerprint, :delivery_id]
      change set_attribute(:status, :sending)
    end

    read :find do
      argument :install_fingerprint, :string, allow_nil?: false
      argument :delivery_id, :uuid, allow_nil?: false

      filter expr(
               install_fingerprint == ^arg(:install_fingerprint) and
                 delivery_id == ^arg(:delivery_id)
             )
    end

    update :finish do
      accept []
      require_atomic? false

      argument :status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:sent, :failed, :unregistered]]

      validate attribute_equals(:status, :sending)
      change set_attribute(:status, arg(:status))
    end

    update :reclaim do
      accept []
      change set_attribute(:status, :sending)
    end

    destroy :expire do
      accept []
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :install_fingerprint, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :delivery_id, :uuid, allow_nil?: false, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:sending, :sent, :failed, :unregistered]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :delivery, [:install_fingerprint, :delivery_id]
  end
end
