defmodule Marshall.Redaction.Coordinator do
  @moduledoc "Oban coordinator that advances bounded inactive-thread scrub batches."
  use Oban.Worker, queue: :redaction, max_attempts: 10
  import Ecto.Query
  alias Marshall.Redaction.{Run, Scanner}

  @batch_size 250

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    with {:ok, run} <- Ash.get(Run, run_id, actor: Marshall.Authorization.SystemActor.compute()),
         :ok <- ensure_running(run),
         {:ok, count} <- process_batch(run) do
      if count == @batch_size do
        _ = %{run_id: run_id} |> new() |> Oban.insert()
      else
        _ =
          Ash.update(
            run,
            :complete,
            %{
              processed: run.processed,
              changed: run.changed,
              skipped: run.skipped,
              failed: run.failed
            }, actor: Marshall.Authorization.SystemActor.compute())
      end

      :ok
    end
  end

  def perform(%Oban.Job{}), do: {:error, :invalid_arguments}

  defp ensure_running(%Run{state: :queued} = run) do
    case Ash.update(run, :start, %{}, actor: Marshall.Authorization.SystemActor.compute()) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp ensure_running(%Run{state: :running}), do: :ok

  defp ensure_running(%Run{state: state}) when state in [:paused, :cancelled, :completed],
    do: {:error, state}

  defp ensure_running(_), do: {:error, :not_found}

  defp process_batch(run) do
    rows =
      from(e in "agent_events",
        join: t in "agent_threads",
        on: t.id == e.thread_id,
        join: r in "agent_roots",
        on: r.id == t.root_id,
        join: v in "compute_virtual_machines",
        on: v.id == r.vm_id,
        where: v.desired_state in ["paused", "stopped"],
        where:
          fragment("?->>'redaction_profile' IS DISTINCT FROM ?", e.body, ^run.profile_digest),
        order_by: [asc: e.id],
        limit: ^@batch_size,
        select: %{id: e.id, body: e.body}
      )
      |> Marshall.Repo.all()

    results =
      rows
      |> Task.async_stream(
        fn %{id: id, body: body} ->
          {redacted, findings} = Scanner.redact_json(body)
          {id, redacted, findings}
        end,
        max_concurrency: 4,
        ordered: true,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    changed =
      Enum.count(results, fn {id, body, findings} ->
        update_event(id, body, findings, run.profile_digest)
      end)

    _ =
      Ash.update(
        run,
        :progress,
        %{
          processed: run.processed + length(rows),
          changed: run.changed + changed,
          skipped: 0,
          failed: 0
        }, actor: Marshall.Authorization.SystemActor.compute())

    {:ok, length(rows)}
  end

  defp update_event(id, body, findings, profile) do
    body = Map.put(body, "redaction_profile", profile)
    body = if findings == [], do: body, else: Map.put(body, "redaction_findings", findings)

    {count, _} =
      Marshall.Repo.update_all(from(e in "agent_events", where: e.id == ^id), set: [body: body])

    count == 1 and findings != []
  end
end