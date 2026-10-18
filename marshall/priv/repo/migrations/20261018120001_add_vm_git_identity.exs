defmodule Marshall.Repo.Migrations.AddVmGitIdentity do
  use Ecto.Migration

  def change do
    alter table(:compute_virtual_machines) do
      add :git_identity, :map
    end
  end
end
