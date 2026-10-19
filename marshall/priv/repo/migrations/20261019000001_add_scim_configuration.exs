defmodule Marshall.Repo.Migrations.AddScimConfiguration do
  use Ecto.Migration

  def change do
    create table(:scim_configurations) do
      add :state, :text, null: false, default: "disabled"
      add :key, :text, null: false, default: "installation"
      add :token_digest, :text
      add :oidc_issuer, :text
      add :oidc_client_id, :text
      add :oidc_client_secret, :text
      add :enabled_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scim_configurations, [:key])

    create constraint(:scim_configurations, :scim_singleton_state,
             check: "state IN ('disabled', 'enabled')"
           )
  end
end
