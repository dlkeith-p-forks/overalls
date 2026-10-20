defmodule Marshall.Repo.Migrations.UserMachineDefaults do
  use Ecto.Migration

  @spec change() :: :ok
  def change do
    alter table(:users) do
      add :launch_default_profile, :text, null: false, default: "oss"
      add :launch_default_image_id, :text
      add :launch_default_vcpu, :bigint
      add :launch_default_memory_bytes, :bigint
      add :launch_default_disk_bytes, :bigint

      add :machine_default_profile, :text, null: false, default: "standard"
      add :machine_default_image_id, :text
      add :machine_default_vcpu, :bigint
      add :machine_default_memory_bytes, :bigint
      add :machine_default_disk_bytes, :bigint

      add :thread_default_profile, :text, null: false, default: "standard"
      add :thread_default_image_id, :text
      add :thread_default_vcpu, :bigint
      add :thread_default_memory_bytes, :bigint
      add :thread_default_disk_bytes, :bigint
    end

    :ok
  end
end
