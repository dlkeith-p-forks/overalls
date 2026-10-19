defmodule Susan.Relay.KeyDenial do
  @moduledoc """
  The push key-id deny-list. A denied key id is refused at authentication for
  the rest of its 90-day life; entries are pruned once every key they could
  match has expired.
  """
  use Ash.Resource,
    otp_app: :susan,
    domain: Susan.Relay,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "key_denials"
    repo Susan.Repo
  end

  code_interface do
    define :deny, args: [:key_id, :reason]
    define :denied, args: [:key_id], get?: true, not_found_error?: false
  end

  actions do
    defaults [:read]

    create :deny do
      accept [:key_id, :reason]
      upsert? true
      upsert_identity :key_id
      upsert_fields [:reason]
    end

    read :denied do
      argument :key_id, :uuid, allow_nil?: false
      filter expr(key_id == ^arg(:key_id))
    end

    destroy :expire do
      accept []
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :key_id, :uuid, allow_nil?: false, public?: true

    attribute :reason, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:operator, :abuse, :compromised]]

    create_timestamp :inserted_at
  end

  identities do
    identity :key_id, [:key_id]
  end
end
