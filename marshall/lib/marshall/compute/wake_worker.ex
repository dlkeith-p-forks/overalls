defmodule Marshall.Compute.WakeWorker do
  @moduledoc "Retries capacity demand without exhausting an indefinitely waiting wake."
  use Oban.Worker,
    queue: :provisioning,
    unique: [
      period: :infinity,
      keys: [:wake_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl true
  @spec perform(Oban.Job.t()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def perform(%Oban.Job{args: %{"wake_id" => id}}) do
    case Marshall.Compute.Wake.advance(id) do
      {:ok, :finished} -> :ok
      {:ok, :waiting} -> {:snooze, 5}
      {:error, reason} -> {:error, reason}
    end
  end
end
