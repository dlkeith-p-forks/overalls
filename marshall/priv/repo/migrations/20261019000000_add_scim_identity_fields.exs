defmodule Marshall.Repo.Migrations.AddScimIdentityFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :active, :boolean, null: false, default: true
      add :scim_external_id, :text
    end

    create unique_index(:users, [:scim_external_id], where: "scim_external_id IS NOT NULL")
  end
end
