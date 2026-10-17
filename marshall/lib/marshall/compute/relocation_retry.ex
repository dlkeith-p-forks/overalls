defmodule Marshall.Compute.RelocationRetry do
  @moduledoc "Retained user request to stop and reactivate only a committed destination."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "compute_relocation_retries"
    repo Marshall.Repo
    identity_wheres_to_sql one_pending_retry: "finished_at IS NULL"

    references do
      reference :relocation, match_with: [vm_id: :vm_id]

      reference :stop_operation,
        match_with: [relocation_id: :relocation_id, stop_generation: :generation]

      reference :start_operation,
        match_with: [relocation_id: :relocation_id, start_generation: :generation]
    end

    check_constraints do
      check_constraint :start_generation, "relocation_retry_activation_complete",
        check: """
        stop_generation > 0 AND (
          (start_operation_id IS NULL AND start_generation IS NULL)
          OR (start_operation_id IS NOT NULL AND start_generation IS NOT NULL AND start_generation > stop_generation AND finished_at IS NOT NULL)
        )
        """
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] relocation-retry-retained-identity
  # Each actor/relocation/key MUST retain one retry and its immutable stop authority.
  # At most one unfinished retry may exist per relocation. Activation references
  # MUST name a later generation of that same relocation; supersession grants no
  # activation. Previous failed readiness results MUST remain immutable history.
  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :activate, from: [:pending], to: :activated
      transition :supersede, from: [:pending], to: :superseded
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :relocation_id,
        :vm_id,
        :requested_by_id,
        :request_key,
        :stop_operation_id,
        :stop_generation
      ]
    end

    update :activate do
      accept [:start_operation_id, :start_generation, :finished_at]
      change transition_state(:activated)
    end

    update :supersede do
      accept [:finished_at]
      change transition_state(:superseded)
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id

    attribute :request_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :stop_generation, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :start_generation, :integer, constraints: [min: 1, max: 9_223_372_036_854_775_807]
    attribute :finished_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :relocation, Marshall.Compute.Relocation, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User, allow_nil?: false
    belongs_to :stop_operation, Marshall.Compute.Operation, allow_nil?: false
    belongs_to :start_operation, Marshall.Compute.Operation
  end

  identities do
    identity :request_identity, [:relocation_id, :requested_by_id, :request_key]
    identity :one_pending_retry, [:relocation_id], where: expr(is_nil(finished_at))
  end
end
