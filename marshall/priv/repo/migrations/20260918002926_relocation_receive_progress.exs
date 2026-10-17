defmodule Marshall.Repo.Migrations.RelocationReceiveProgress do
  @moduledoc "Persist one bounded, non-authoritative receive progress observation per relocation."
  use Ecto.Migration

  def up do
    alter table(:compute_relocations) do
      add :receive_progress, :map
    end
  end

  def down do
    alter table(:compute_relocations) do
      remove :receive_progress
    end
  end
end
