defmodule Marshall.Repo.Migrations.InitializeWorkflowServiceLevelSources do
  @moduledoc "Initialize only the four new workflow measurement lifetimes."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:durability;deployment] workflow-source-lifetimes
  # The migration MUST initialize the four new sources once before admission.
  # It MUST NOT change any existing source identity, counter or measurement.
  @spec up() :: :ok
  def up do
    execute """
    INSERT INTO compute_service_level_totals
      (service, started_at, requests, successes, failures, duration_sum_us, bucket_counts)
    SELECT service, clock_timestamp() AT TIME ZONE 'utc', 0, 0, 0, 0,
      ARRAY[0,0,0,0,0,0,0,0]::bigint[]
    FROM (VALUES ('porsche_clone'), ('porsche_relocate'), ('porsche_retry'), ('porsche_cancel')) AS sources(service)
    ON CONFLICT (service) DO NOTHING
    """
  end

  @spec down() :: no_return()
  def down,
    do: raise("Workflow measurement lifetimes are permanent; use a compatible corrective release")
end
