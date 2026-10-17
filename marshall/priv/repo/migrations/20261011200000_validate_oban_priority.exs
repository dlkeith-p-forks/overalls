defmodule Marshall.Repo.Migrations.ValidateObanPriority do
  @moduledoc "ADR-0159: validate Oban's NOT VALID priority constraint so none remains unvalidated."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence] no-unvalidated-constraints
  # Oban adds `non_negative_priority` NOT VALID. After this migration no
  # constraint in the schema remains NOT VALID.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("ALTER TABLE oban_jobs VALIDATE CONSTRAINT non_negative_priority")
    :ok
  end

  @spec down() :: :ok
  def down, do: :ok
end
