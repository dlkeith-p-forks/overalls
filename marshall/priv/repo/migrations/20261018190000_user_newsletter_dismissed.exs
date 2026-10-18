defmodule Marshall.Repo.Migrations.UserNewsletterDismissed do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:newsletter_dismissed, :boolean, null: false, default: false)
    end
  end

  def down do
    alter table(:users) do
      remove(:newsletter_dismissed)
    end
  end
end
