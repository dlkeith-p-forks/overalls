defmodule Marshall.Compute.ServiceLevelTotals do
  @moduledoc "Serialized terminal aggregation and fixed numeric snapshot projection."
  alias Marshall.Compute.{Ledger, ServiceLevelAttempt, ServiceLevelTotal}
  @bounds [1_000_000, 5_000_000, 10_000_000, 30_000_000, 120_000_000, 600_000_000, 3_000_000_000]
  @type service ::
          Marshall.Compute.ServiceLevels.service()
          | Marshall.Compute.WorkflowServiceLevels.service()
  @type snapshot :: Marshall.SLO.snapshot()

  # @cc [owner:ghuntley,label:concurrency;durability] service-level-total-single-commit
  # Totals MUST be row-locked and added only in the transaction
  # that first finishes a locked attempt. Its permanent lifetime MUST survive
  # process restart. No operation, VM, requester or provider identifier may be
  # exported; totals MUST NOT grant any execution authority.
  @spec ensure!(service()) :: ServiceLevelTotal.t()
  def ensure!(service)
      when service in [
             :marshall_ready,
             :lilly_physical,
             :porsche_physical,
             :porsche_clone,
             :porsche_relocate,
             :porsche_retry,
             :porsche_cancel
           ] do
    case Ledger.read!(ServiceLevelTotal, service: service) do
      [] -> Ledger.rollback(:service_level_source_unavailable)
      [row] -> row
    end
  end

  @spec add!(ServiceLevelAttempt.t() | Marshall.Compute.WorkflowServiceLevelAttempt.t()) :: :ok
  def add!(%{status: :finished, success: success} = attempt) when is_boolean(success) do
    source = ensure!(attempt.service)
    row = Ledger.lock!(ServiceLevelTotal, source.id)
    bucket = Enum.find_index(@bounds, &(attempt.duration_us <= &1)) || length(@bounds)

    Ledger.update!(row, :add, %{
      requests: row.requests + 1,
      successes: row.successes + if(attempt.success, do: 1, else: 0),
      failures: row.failures + if(attempt.success, do: 0, else: 1),
      duration_sum_us: row.duration_sum_us + attempt.duration_us,
      bucket_counts: List.update_at(row.bucket_counts, bucket, &(&1 + 1))
    })

    :ok
  end

  @spec snapshot(ServiceLevelTotal.t(), DateTime.t()) :: snapshot()
  def snapshot(row, now) do
    identity = String.replace(row.id, "-", "")

    %{
      version: 1,
      service: Atom.to_string(row.service),
      sampled_at_unix_nano: DateTime.to_unix(now, :nanosecond),
      started_at_unix_nano: DateTime.to_unix(row.started_at, :nanosecond),
      incarnation: identity,
      invocation_id: identity,
      requests: row.requests,
      successes: row.successes,
      failures: row.failures,
      duration: %{
        count: row.requests,
        sum_us: row.duration_sum_us,
        explicit_bounds_us: @bounds,
        bucket_counts: row.bucket_counts
      }
    }
  end
end
