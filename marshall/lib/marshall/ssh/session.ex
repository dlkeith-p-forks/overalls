defmodule Marshall.SSH.Session do
  @moduledoc "A gateway-bound SSH connection; expiry and key identity are durable."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.SSH,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban]

  postgres do
    table "ssh_sessions"
    repo Marshall.Repo

    custom_indexes do
      index [:gateway_id, :expires_at]
      index [:expires_at, :id]
    end
  end

  oban do
    scheduled_actions do
      schedule :prune, "*/10 * * * *" do
        action :prune
        queue :maintenance
        max_attempts 5
        worker_module_name Marshall.SSH.Workers.PruneSessions
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:token_hash, :gateway_id, :gateway_generation, :key_id, :expires_at]
    end

    update :approve do
      accept [:key_id, :expires_at]
    end

    update :close do
      accept [:closed_at]
    end

    destroy :purge

    action :prune, :integer do
      argument :continuation, :uuid
      run Marshall.SSH.Retention
    end

    action :open_session, :map do
      argument :gateway_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :public_key, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 4096, trim?: false]

      run {Marshall.SSH.Authority, operation: :open}
    end

    action :session_status, :map do
      argument :gateway_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :session_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      run {Marshall.SSH.Authority, operation: :status}
    end

    action :close_session, :map do
      argument :gateway_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :session_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      run {Marshall.SSH.Authority, operation: :close}
    end

    action :list_for_admin, {:array, :map} do
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 100]
      run {Marshall.SSH.AdminActions, operation: :list_sessions}
    end

    action :revoke_for_admin, :map do
      argument :id, :uuid, allow_nil?: false
      run {Marshall.SSH.AdminActions, operation: :revoke_session}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :gateway_generation, :integer, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :closed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :gateway, Marshall.SSH.Gateway, allow_nil?: false
    belongs_to :key, Marshall.SSH.Key
  end

  identities do
    identity :token_hash, [:token_hash]
  end
end
