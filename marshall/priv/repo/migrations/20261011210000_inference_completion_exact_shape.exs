defmodule Marshall.Repo.Migrations.InferenceCompletionExactShape do
  @moduledoc "ADR-0159 Push 8 (M19): require the exact inference completion wire shape."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:accounting] inference-completion-exact-shape
  # PostgreSQL MUST refuse a stored completion that is not the exact accounting
  # wire shape: an object with outcome, tokens and completeness and at most an
  # additional cost_estimate.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE inference_requests
    ADD CONSTRAINT inference_completion_exact_shape CHECK (#{exact()})
    """)

    :ok
  end

  @spec down() :: :ok
  def down do
    execute("ALTER TABLE inference_requests DROP CONSTRAINT inference_completion_exact_shape")
    :ok
  end

  @spec exact() :: String.t()
  defp exact,
    do:
      "completion IS NULL OR (jsonb_typeof(completion) = 'object' AND " <>
        "(completion - ARRAY['outcome', 'tokens', 'completeness', 'cost_estimate']) = '{}'::jsonb AND " <>
        "completion ?& ARRAY['outcome', 'tokens', 'completeness'])"
end
