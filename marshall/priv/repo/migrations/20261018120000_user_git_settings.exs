defmodule Marshall.Repo.Migrations.UserGitSettings do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :git_username, :text, null: false, default: "Overalls"
      add :git_email, :citext, null: false, default: "noreply@overalls.dev"
      add :commit_trailers_enabled, :boolean, null: false, default: true
    end
  end
end
