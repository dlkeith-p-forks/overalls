defmodule Marshall.Redaction.SweepWorker do
  @moduledoc "Periodic inactive-thread redaction sweep."
  use Oban.Worker, queue: :redaction, max_attempts: 3
  import Ecto.Query

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    active_run? =
      from(r in "redaction_runs",
        where: r.state in ["queued", "running", "paused"],
        select: count(r.id)
      )
      |> Marshall.Repo.one!() > 0

    unless active_run?, do: _ = Marshall.Redaction.enqueue(:all_inactive, nil)
    :ok
  end
end