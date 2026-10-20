defmodule Marshall.Agents.Attachment do
  @moduledoc "Thread-owned attachment metadata and state machine."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table("agent_attachments")
    repo(Marshall.Repo)
  end

  state_machine do
    state_attribute(:state)
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:begin_upload, from: [:pending, :failed], to: :uploading)
      transition(:publish, from: [:uploading], to: :available)
      transition(:quarantine, from: [:uploading, :available], to: :quarantined)
      transition(:fail, from: [:pending, :uploading], to: :failed)

      transition(:begin_delete,
        from: [:available, :quarantined, :failed, :deleting],
        to: :deleting
      )

      transition(:finish_delete, from: [:deleting], to: :deleted)
    end
  end

  actions do
    defaults([:read])

    create :create_pending do
      accept([:thread_id, :owner_id, :idempotency_key, :display_name])
    end

    update :begin_upload do
      accept([])
      change(transition_state(:uploading))
    end

    update :publish do
      accept([:storage_key, :sha256, :size_bytes, :media_type])
      change(transition_state(:available))
    end

    update :quarantine do
      accept([:failure_reason])
      change(transition_state(:quarantined))
    end

    update :fail do
      accept([:failure_reason])
      change(transition_state(:failed))
    end

    update :begin_delete do
      accept([])
      change(transition_state(:deleting))
    end

    update :finish_delete do
      accept([])
      change(transition_state(:deleted))
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:thread_id, :uuid, allow_nil?: false)
    attribute(:owner_id, :uuid, allow_nil?: false)

    attribute(:state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [
        one_of: [:pending, :uploading, :available, :quarantined, :failed, :deleting, :deleted]
      ]
    )

    attribute(:storage_key, :string)
    attribute(:sha256, :string)
    attribute(:size_bytes, :integer)
    attribute(:media_type, :string)
    attribute(:display_name, :string)
    attribute(:idempotency_key, :string, allow_nil?: false)
    attribute(:failure_reason, :string)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:thread_idempotency, [:thread_id, :idempotency_key])
  end
end