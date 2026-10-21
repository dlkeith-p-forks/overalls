defmodule Marshall.Repo.Migrations.AttachmentSystemAudits do
  use Ecto.Migration
  @spec up() :: term()
  def up, do: execute("ALTER TABLE agent_attachment_audits ALTER COLUMN actor_id DROP NOT NULL")
  @spec down() :: term()
  def down, do: execute("ALTER TABLE agent_attachment_audits ALTER COLUMN actor_id SET NOT NULL")
end
