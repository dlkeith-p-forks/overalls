defmodule Marshall.Repo.Migrations.WorkspaceSourceV2 do
  @moduledoc "Replace the GitHub-only workspace source columns with provider-neutral ones."
  use Ecto.Migration

  def up do
    drop constraint(:compute_workspace_sources, :valid_workspace_ref_kind)
    drop constraint(:compute_workspace_sources, :workspace_ref_matches_kind)

    alter table(:compute_workspace_sources) do
      add :provider, :text
      add :namespace, {:array, :text}
      add :repository, :text
      add :revision, :map
    end

    alter table(:compute_workspace_sources) do
      modify :provider, :text, null: false
      modify :namespace, {:array, :text}, null: false
      modify :repository, :text, null: false
      modify :revision, :map, null: false
      remove :owner
      remove :repo
      remove :ref_kind
      remove :ref
    end

    create constraint(:compute_workspace_sources, :valid_workspace_provider,
             check: "provider IN ('github','gitlab','codeberg','bitbucket')"
           )

    create constraint(:compute_workspace_sources, :valid_workspace_revision,
             check: "revision->>'kind' IN ('default','ref','tag','commit','change')"
           )
  end

  def down do
    raise "source-v2 cutover is irreversible; restore a pre-cutover database backup"
  end
end
