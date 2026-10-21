defmodule Susan.Maintenance.Prune do
  @moduledoc """
  Daily retention job: audit entries after 90 days (itself audited), delivery
  receipts after 24 hours, unregistered-token digests after 30 days and
  key-id denials after 91 days, when every key they could match has expired.
  The job takes no arguments, so Oban rows carry no request data.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3_600]

  alias Susan.Relay.{DeliveryReceipt, KeyDenial, UnregisteredToken}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    with :ok <- Susan.Audit.Log.reconcile_receipts(),
         {:ok, _count} <- Susan.Audit.Log.prune(now),
         :ok <- expire(DeliveryReceipt, :inserted_at, DateTime.add(now, -86_400, :second)),
         :ok <- expire(UnregisteredToken, :recorded_at, DateTime.add(now, -30 * 86_400, :second)),
         :ok <- expire(KeyDenial, :inserted_at, DateTime.add(now, -91 * 86_400, :second)) do
      :ok
    else
      _ -> {:error, :prune_failed}
    end
  end

  @spec expire(module(), atom(), DateTime.t()) :: :ok | :error
  defp expire(resource, field, cutoff) do
    resource
    |> Ash.Query.do_filter(%{field => %{less_than: cutoff}})
    |> Ash.bulk_destroy(:expire, %{}, strategy: [:atomic, :stream], return_errors?: true)
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      _ -> :error
    end
  end
end
