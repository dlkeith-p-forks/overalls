defmodule Marshall.Repo.Migrations.InitializeServiceLevelSources do
  @moduledoc "Initialize the three fixed measurement lifetimes before application admission."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:deployment;durability] service-level-source-initialization
  # Migration MUST initialize each fixed source exactly once, before dependent
  # admission code starts. It MUST NOT replace existing lifetimes or counters.
  # Source rows contain no credential or user identity and are permanent.
  @spec up() :: :ok
  def up do
    execute """
    INSERT INTO compute_service_level_totals
      (service, started_at, requests, successes, failures, duration_sum_us, bucket_counts)
    SELECT service, clock_timestamp() AT TIME ZONE 'utc', 0, 0, 0, 0,
      ARRAY[0,0,0,0,0,0,0,0]::bigint[]
    FROM (VALUES ('lilly_physical'), ('marshall_ready'), ('porsche_physical')) AS sources(service)
    ON CONFLICT (service) DO NOTHING
    """
  end

  @spec down() :: no_return()
  def down do
    raise "Service level lifetimes are permanent; use a compatible corrective release"
  end
end
