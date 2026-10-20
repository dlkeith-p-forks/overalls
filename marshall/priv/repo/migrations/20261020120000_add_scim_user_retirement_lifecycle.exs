defmodule Marshall.Repo.Migrations.AddScimUserRetirementLifecycle do
  @moduledoc """
  SCIM user retirement: soft SCIM deletion, the deletion kind that selects its
  machine-deletion authority, and durable records of machines SCIM suspended.
  """
  use Ecto.Migration

  @spec change() :: term()
  def change do
    alter table(:users) do
      add :scim_deleted_at, :utc_datetime_usec
    end

    alter table(:account_user_deletions) do
      add :kind, :text, null: false, default: "administrator"
    end

    create constraint(:account_user_deletions, :user_deletion_kind,
             check: "kind IN ('administrator', 'scim_retirement')"
           )

    create table(:scim_machine_suspensions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false

      add :vm_id, references(:compute_virtual_machines, type: :uuid, on_delete: :restrict),
        null: false

      add :kind, :text, null: false
      add :state, :text, null: false, default: "suspended"
      add :retirement_deadline, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create constraint(:scim_machine_suspensions, :scim_machine_suspension_kind,
             check: "kind IN ('pause', 'stop')"
           )

    create constraint(:scim_machine_suspensions, :scim_machine_suspension_state,
             check: "state IN ('suspended', 'resumed', 'released')"
           )

    create unique_index(:scim_machine_suspensions, [:vm_id],
             where: "state = 'suspended'",
             name: :scim_machine_suspensions_one_open_index
           )

    create index(:scim_machine_suspensions, [:user_id, :state])

    # Deletions completed before the state machine was enforced kept the
    # default state; record their completion as the terminal transition.
    execute(
      "UPDATE account_user_deletions SET state = 'completed' WHERE completed_at IS NOT NULL AND state <> 'completed'",
      "SELECT 1"
    )
  end
end
