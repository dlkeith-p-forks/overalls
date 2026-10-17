defmodule Marshall.Repo.Migrations.AgentExecutorBinaryDigest do
  use Ecto.Migration

  def change do
    alter table(:agent_executors) do
      add :binary_sha256, :string
    end

    create constraint(:agent_executors, :agent_executors_binary_sha256_format,
             check: "binary_sha256 IS NULL OR binary_sha256 ~ '^[0-9a-f]{64}$'"
           )
  end
end
