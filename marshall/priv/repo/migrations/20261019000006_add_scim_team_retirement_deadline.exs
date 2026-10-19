defmodule Marshall.Repo.Migrations.AddScimTeamRetirementDeadline do
  use Ecto.Migration

  def change do
    alter table(:teams) do
      add :scim_retirement_deadline, :utc_datetime_usec
    end

    create index(:teams, [:management_mode, :scim_retirement_deadline])
  end
end
