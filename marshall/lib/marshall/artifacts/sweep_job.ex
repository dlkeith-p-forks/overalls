defmodule Marshall.Artifacts.SweepJob do
  @moduledoc "Hourly reclamation of blobs no version references."
  use Oban.Worker, queue: :artifacts, max_attempts: 3, unique: [period: 3_000]

  require Marshall.Events

  @batch 500
  @grace_seconds 3_600

  @impl true
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    {:ok, count} =
      Marshall.Compute.Ledger.transaction(
        fn -> Marshall.Artifacts.Blobs.sweep!(@batch, @grace_seconds) end,
        {:system, nil}
      )

    if count > 0 do
      Marshall.Events.emit("artifact.blobs_swept", count: count)
      if count == @batch, do: new(%{}, schedule_in: 5) |> Oban.insert!()
    end

    :ok
  end
end
