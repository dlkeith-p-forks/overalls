defmodule Marshall.Repo.Migrations.AgentCancelledModelCalls do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE agent_model_calls DROP CONSTRAINT agent_model_calls_state_check")

    execute("""
    ALTER TABLE agent_model_calls
      ADD CONSTRAINT agent_model_calls_state_check CHECK (
        iteration BETWEEN 1 AND 64 AND execution_epoch > 0 AND
        status IN ('queued', 'claimed', 'completed', 'failed', 'uncertain', 'cancelled') AND
        octet_length(request::text) <= 262144 AND
        (response IS NULL OR octet_length(response::text) <= 1048576) AND
        ((status = 'queued' AND claim_id IS NULL AND claimed_at IS NULL AND finished_at IS NULL) OR
         (status = 'cancelled' AND claim_id IS NULL AND claimed_at IS NULL AND finished_at IS NOT NULL) OR
         (status = 'claimed' AND claim_id IS NOT NULL AND claimed_at IS NOT NULL AND finished_at IS NULL) OR
         (status IN ('completed', 'failed', 'uncertain') AND claim_id IS NOT NULL AND
          claimed_at IS NOT NULL AND finished_at IS NOT NULL))
      )
    """)
  end

  def down do
    execute("ALTER TABLE agent_model_calls DROP CONSTRAINT agent_model_calls_state_check")

    execute("""
    ALTER TABLE agent_model_calls
      ADD CONSTRAINT agent_model_calls_state_check CHECK (
        iteration BETWEEN 1 AND 64 AND execution_epoch > 0 AND
        status IN ('queued', 'claimed', 'completed', 'failed', 'uncertain') AND
        octet_length(request::text) <= 262144 AND
        (response IS NULL OR octet_length(response::text) <= 1048576) AND
        ((status = 'queued' AND claim_id IS NULL AND claimed_at IS NULL AND finished_at IS NULL) OR
         (status = 'claimed' AND claim_id IS NOT NULL AND claimed_at IS NOT NULL AND finished_at IS NULL) OR
         (status IN ('completed', 'failed', 'uncertain') AND claim_id IS NOT NULL AND
          claimed_at IS NOT NULL AND finished_at IS NOT NULL))
      )
    """)
  end
end
