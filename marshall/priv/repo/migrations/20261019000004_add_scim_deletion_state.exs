defmodule Marshall.Repo.Migrations.AddScimDeletionState do
  use Ecto.Migration

  def change do
    alter table(:account_user_deletions) do
      add :state, :text, null: false, default: "scheduled"
    end

    create constraint(:account_user_deletions, :user_deletion_state,
             check: "state IN ('scheduled', 'finalizing', 'cancelled', 'completed')"
           )
  end
end
