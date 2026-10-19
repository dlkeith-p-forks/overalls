defmodule Marshall.Repo.Migrations.AddScimRetirementDeadline do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :scim_retirement_deadline, :utc_datetime_usec
    end
  end
end
