defmodule Marshall.Scim.Configuration do
  @moduledoc "Singleton SCIM configuration with closed enable/disable transitions."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Scim,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshArchival.Resource]

  postgres do
    table "scim_configurations"
    repo Marshall.Repo
  end

  state_machine do
    initial_states [:disabled]
    default_initial_state :disabled

    transitions do
      transition :enable, from: [:disabled], to: :enabled
      transition :disable, from: [:enabled], to: :disabled
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :token_digest,
        :state,
        :enabled_at,
        :oidc_issuer,
        :oidc_client_id,
        :oidc_client_secret
      ]
    end

    update :enable do
      accept []
      change transition_state(:enabled)
      require_atomic? false
    end

    update :disable do
      accept []
      change transition_state(:disabled)
      require_atomic? false
    end

    update :rotate_token do
      accept [:token_digest, :oidc_issuer, :oidc_client_id, :oidc_client_secret]
      require_atomic? false
    end

    action :configure, :map do
      argument :enabled, :boolean, allow_nil?: false
      argument :rotate_token, :boolean, allow_nil?: false, default: false
      argument :oidc_issuer, :string, allow_nil?: true
      argument :oidc_client_id, :string, allow_nil?: true
      argument :oidc_client_secret, :string, allow_nil?: true, sensitive?: true
      run Marshall.Scim.ConfigurationActions
    end
  end

  policies do
    policy action(:configure) do
      authorize_if Marshall.Accounts.Checks.Administrator
    end

    policy always() do
      authorize_if Marshall.Accounts.Checks.InternalLookup
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :state, :atom,
      allow_nil?: false,
      default: :disabled,
      constraints: [one_of: [:disabled, :enabled]]

    attribute :key, :string, allow_nil?: false, default: "installation"
    attribute :token_digest, :string, allow_nil?: true, sensitive?: true
    attribute :oidc_issuer, :string, allow_nil?: true
    attribute :oidc_client_id, :string, allow_nil?: true
    attribute :oidc_client_secret, :string, allow_nil?: true, sensitive?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
    attribute :enabled_at, :utc_datetime_usec
  end

  identities do
    identity :singleton, [:key]
  end
end
