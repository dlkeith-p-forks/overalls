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
         {:ok, processed, has_more?} <- process_batch(run) do
      if has_more? do
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
    events =
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

    turns =
      from(t in "agent_turns",
        join: th in "agent_threads", on: th.id == t.thread_id,
        join: r in "agent_roots", on: r.id == th.root_id,
        join: v in "compute_virtual_machines", on: v.id == r.vm_id,
        where: v.desired_state in ["paused", "stopped"],
        where: not is_nil(t.prompt),
        where: is_nil(t.redaction_profile) or t.redaction_profile != ^run.profile_digest,
        order_by: [asc: t.id], limit: ^@batch_size,
        select: %{id: t.id, prompt: t.prompt}
      )
      |> Marshall.Repo.all()

    commands =
      from(c in "agent_commands",
        join: r in "agent_roots", on: r.id == c.root_id,
        join: v in "compute_virtual_machines", on: v.id == r.vm_id,
        where: v.desired_state in ["paused", "stopped"],
        where: is_nil(c.redaction_profile) or c.redaction_profile != ^run.profile_digest,
        order_by: [asc: c.id], limit: ^@batch_size,
        select: %{id: c.id, arguments: c.arguments, result: c.result}
      )
      |> Marshall.Repo.all()

    event_results = scan(events, fn %{body: body} -> body end)
    turn_results = scan(turns, fn %{prompt: prompt} -> prompt end)
    command_results =
      commands
      |> Task.async_stream(
        fn %{arguments: arguments, result: result} ->
          {redacted_arguments, argument_findings} = Scanner.redact_json(arguments)
          {redacted_result, result_findings} =
            case result do
              nil -> {nil, []}
              value -> Scanner.redact_json(value)
            end
          {{redacted_arguments, argument_findings}, {redacted_result, result_findings}}
        end,
        max_concurrency: 4,
        ordered: true,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    changed =
      update_events(events, event_results, run.profile_digest) +
        update_turns(turns, turn_results, run.profile_digest) +
        update_commands(commands, command_results, run.profile_digest)

    processed = length(events) + length(turns) + length(commands)

    _ =
      Ash.update(
        run,
        :progress,
        %{
          processed: run.processed + processed,
          changed: run.changed + changed,
          skipped: 0,
          failed: 0
        }, actor: Marshall.Authorization.SystemActor.compute())

    {:ok, processed, more_rows?(run.profile_digest)}
  end

  defp more_rows?(profile) do
    event? = from(e in "agent_events", where: fragment("?->>'redaction_profile' IS DISTINCT FROM ?", e.body, ^profile), limit: 1, select: e.id) |> Marshall.Repo.exists?()
    turn? = from(t in "agent_turns", where: is_nil(t.redaction_profile) or t.redaction_profile != ^profile, limit: 1, select: t.id) |> Marshall.Repo.exists?()
    command? = from(c in "agent_commands", where: is_nil(c.redaction_profile) or c.redaction_profile != ^profile, limit: 1, select: c.id) |> Marshall.Repo.exists?()
    event? or turn? or command?
  end

  defp scan(rows, fun) do
    rows
    |> Task.async_stream(fn row -> {row, Scanner.redact_json(fun.(row))} end,
      max_concurrency: 4, ordered: true, timeout: 10_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp update_events(_rows, results, profile) do
    Enum.count(results, fn {%{id: id}, {body, findings}} ->
      body = body |> Map.put("redaction_profile", profile) |> put_findings(findings)
      {count, _} = Marshall.Repo.update_all(from(e in "agent_events", where: e.id == ^id), set: [body: body])
      count == 1 and findings != []
    end)
  end

  defp update_turns(_rows, results, profile) do
    Enum.count(results, fn {%{id: id}, {prompt, findings}} ->
      {count, _} = Marshall.Repo.update_all(from(t in "agent_turns", where: t.id == ^id), set: [prompt: prompt, redaction_profile: profile])
      count == 1 and findings != []
    end)
  end

  defp update_commands(_rows, results, profile) do
    Enum.count(results, fn {%{id: id}, {{arguments, argument_findings}, {result, result_findings}}} ->
      {count, _} = Marshall.Repo.update_all(from(c in "agent_commands", where: c.id == ^id), set: [arguments: arguments, result: result, redaction_profile: profile])
      count == 1 and (argument_findings != [] or result_findings != [])
    end)
  end

  defp put_findings(map, []), do: map
  defp put_findings(map, findings), do: Map.put(map, "redaction_findings", findings)

end
