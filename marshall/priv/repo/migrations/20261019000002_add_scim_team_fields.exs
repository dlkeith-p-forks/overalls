defmodule Marshall.Repo.Migrations.AddScimTeamFields do
  use Ecto.Migration

  def change do
    alter table(:teams) do
      add :scim_external_id, :text
      add :management_mode, :text, null: false, default: "native"
    end

    create unique_index(:teams, [:scim_external_id], where: "scim_external_id IS NOT NULL")

    create constraint(:teams, :team_management_mode,
             check: "management_mode IN ('native', 'scim_managed', 'retiring', 'handoff_pending')"
           )
  end
end
