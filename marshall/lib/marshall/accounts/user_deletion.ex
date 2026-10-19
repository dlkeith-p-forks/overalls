defmodule Marshall.Accounts.UserDeletion do
  @moduledoc "Durable account retirement; completion requires all owned VMs to be reclaimed."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban, AshStateMachine]

  postgres do
    table "account_user_deletions"
    repo Marshall.Repo

    custom_indexes do
      index [:email, :inserted_at]
    end
  end

  oban do
    triggers do
      trigger :advance do
        action :advance
        queue :maintenance
        where expr(is_nil(completed_at))
        scheduler_cron "* * * * *"
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
        worker_module_name Marshall.Accounts.Workers.DeleteUserMachines
        scheduler_module_name Marshall.Accounts.Workers.ScheduleUserDeletions
      end
    end
  end

  state_machine do
    initial_states [:scheduled]
    default_initial_state :scheduled

    transitions do
      transition :cancel, from: [:scheduled], to: :cancelled
      transition :begin_finalization, from: [:scheduled], to: :finalizing
      transition :complete, from: [:finalizing], to: :completed
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:user_id, :requested_by_id, :email]
      change run_oban_trigger(:advance)
    end

    update :progress do
      accept [:completed_at, :remaining, :blocked, :state]
    end

    update :cancel do
      accept []
      change transition_state(:cancelled)
    end

    update :begin_finalization do
      accept []
      change transition_state(:finalizing)
    end

    update :complete do
      accept []
      change transition_state(:completed)
    end

    action :advance, :map do
      argument :primary_key, :map, allow_nil?: false
      run Marshall.Accounts.DeleteUserMachines
    end
  end

  policies do
    policy always() do
      authorize_if Marshall.Accounts.Checks.InternalLookup
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :email, Marshall.Accounts.EmailAddress, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      default: :scheduled,
      constraints: [one_of: [:scheduled, :finalizing, :cancelled, :completed]]

    attribute :remaining, :integer, allow_nil?: false, default: 0
    attribute :blocked, :boolean, allow_nil?: false, default: false
    attribute :completed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :one_deletion, [:user_id]
  end
end
