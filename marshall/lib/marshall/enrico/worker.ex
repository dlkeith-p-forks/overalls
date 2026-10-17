defmodule Marshall.Enrico.Worker do
  @moduledoc "Oban-owned hourly mirror reconciler with durable Ash transitions."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 4_200, keys: [:id, :op], states: [:available, :scheduled, :executing]]

  alias Marshall.Enrico.{Repository, AuditEvent, Client}
  alias Marshall.Compute.Ledger
  alias Marshall.Authorization.SystemActor
  require Ash.Query
  require Marshall.Events

  @impl true
  def timeout(_job), do: :timer.minutes(70)

  # @cc [owner:ghuntley,label:recovery] enrico-hourly-reconciliation
  # Oban retries and an hourly schedule MUST recover interrupted refreshes;
  # a failed fetch preserves the previously published head and records failure.
  @impl true
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case Ledger.read!(Repository, id: id) do
      [%Repository{phase: :removing} = repo] -> remove(repo)
      [repo] -> refresh(repo)
      [] -> :ok
    end
  end

  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    Repository
    |> Ash.Query.filter(phase == :removing or is_nil(next_refresh_at) or next_refresh_at <= ^now)
    |> Ash.Query.limit(100)
    |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
    |> Enum.each(fn repo ->
      operation = if repo.phase == :removing, do: "remove", else: "refresh"

      case __MODULE__.new(%{"id" => repo.id, "op" => operation}) |> Oban.insert() do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] enrico-current-attempt-settlement
  # Attempt selection and every terminal result MUST lock and re-read the current
  # repository. A replaced attempt or removing repository MUST receive no state,
  # audit or diagnostic outcome from a stale worker. Network waits MUST happen
  # outside the row-lock transaction; failed current attempts retain the head.
  defp refresh(repo) do
    {attempt, submit?, abandoned_reason} = attempt_to_run(repo)

    with {:ok, :started} <- begin_attempt(repo, attempt, submit?, abandoned_reason),
         {:ok, _} <- submit_if_new(repo, attempt, submit?),
         {:ok, head} <- wait_for_attempt(repo.id, attempt, 780) do
      settle(repo.id, attempt, {:ok, head})
    else
      {:error, :superseded} -> :ok
      failure -> settle(repo.id, attempt, {:error, failure_reason(failure)})
    end
  end

  @spec begin_attempt(Repository.t(), String.t(), boolean(), atom() | nil) ::
          {:ok, :started} | {:error, term()}
  defp begin_attempt(observed, attempt, submit?, abandoned_reason) do
    Ledger.transaction(
      fn ->
        current = Ledger.lock!(Repository, observed.id) || Ledger.rollback(:superseded)

        unless current.phase == observed.phase and current.attempt_id == observed.attempt_id and
                 current.phase != :removing,
               do: Ledger.rollback(:superseded)

        now = DateTime.utc_now()

        current =
          if current.phase == :refreshing and submit? do
            failed = Ledger.update!(current, :fail, %{next_refresh_at: now})

            Ledger.create!(AuditEvent, :record, %{
              repository_id: current.id,
              attempt_id: current.attempt_id,
              kind: :refresh_failed,
              failure_reason: abandoned_reason
            })

            Ledger.after_commit(fn ->
              Marshall.Events.emit("enrico.refresh_failed",
                repository_id: current.id,
                reason: abandoned_reason
              )
            end)

            failed
          else
            current
          end

        unless current.phase == :refreshing do
          Ledger.update!(current, :begin_refresh, %{attempt_id: attempt, last_attempt_at: now})
        end

        :started
      end,
      :system
    )
  end

  @spec settle(String.t(), String.t(), {:ok, String.t()} | {:error, atom()}) ::
          :ok | {:error, term()}
  defp settle(id, attempt, outcome) do
    result =
      Ledger.transaction(
        fn ->
          case Ledger.lock!(Repository, id) do
            %Repository{phase: :refreshing, attempt_id: ^attempt} = current ->
              record_outcome!(current, outcome)
              :settled

            _ ->
              :superseded
          end
        end,
        :system
      )

    case {result, outcome} do
      {{:ok, :settled}, {:error, _}} -> {:error, :refresh_failed}
      {{:ok, _}, _} -> :ok
      {{:error, reason}, _} -> {:error, reason}
    end
  end

  @spec record_outcome!(Repository.t(), {:ok, String.t()} | {:error, atom()}) :: :ok
  defp record_outcome!(repo, {:ok, head}) do
    Ledger.update!(repo, :publish, %{
      head: head,
      last_success_at: DateTime.utc_now(),
      next_refresh_at: next_hour()
    })

    Ledger.create!(AuditEvent, :record, %{
      repository_id: repo.id,
      attempt_id: repo.attempt_id,
      kind: :refresh_succeeded
    })

    Ledger.after_commit(fn ->
      Marshall.Events.emit("enrico.refresh_succeeded", repository_id: repo.id)
    end)
  end

  defp record_outcome!(repo, {:error, reason}) do
    Ledger.update!(repo, :fail, %{next_refresh_at: retry_at(reason)})

    Ledger.create!(AuditEvent, :record, %{
      repository_id: repo.id,
      attempt_id: repo.attempt_id,
      kind: :refresh_failed,
      failure_reason: reason
    })

    Ledger.after_commit(fn ->
      Marshall.Events.emit("enrico.refresh_failed", repository_id: repo.id, reason: reason)
    end)
  end

  defp wait_for_attempt(_, _, 0), do: {:error, :timeout}

  defp wait_for_attempt(id, attempt, remaining) do
    case Client.request(:get, id, "attempts/" <> attempt) do
      {:ok, %{"status" => %{"state" => "succeeded", "head" => head}}} when is_binary(head) ->
        {:ok, head}

      {:ok, %{"status" => "failed"}} ->
        {:error, :git_failed}

      {:ok, %{"status" => "missing"}} ->
        {:error, :service_unavailable}

      {:ok, _} ->
        Process.sleep(5_000)
        wait_for_attempt(id, attempt, remaining - 1)

      {:error, reason} when reason in [:timeout, :service_unavailable] ->
        Process.sleep(5_000)
        wait_for_attempt(id, attempt, remaining - 1)

      error ->
        error
    end
  end

  defp next_hour, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  defp retry_at(reason) when reason in [:timeout, :service_unavailable],
    do: DateTime.add(DateTime.utc_now(), 60, :second)

  defp retry_at(_), do: next_hour()

  defp attempt_to_run(%Repository{phase: phase, attempt_id: attempt} = repo)
       when phase in [:refreshing, :failed] and is_binary(attempt) do
    case Client.request(:get, repo.id, "attempts/" <> attempt) do
      {:ok, %{"status" => "failed"}} ->
        {Ash.UUID.generate(), true, :git_failed}

      {:ok, %{"status" => "missing"}} ->
        {Ash.UUID.generate(), true, :service_unavailable}

      _ ->
        {attempt, false, nil}
    end
  end

  defp attempt_to_run(_), do: {Ash.UUID.generate(), true, nil}

  defp submit_if_new(_, _, false), do: {:ok, :resumed}

  defp submit_if_new(repo, attempt, true) do
    Client.request(:post, repo.id, "refresh", %{
      attempt_id: attempt,
      owner: repo.owner,
      repo: repo.name
    })
  end

  defp failure_reason({:error, reason})
       when reason in [:tls_untrusted, :timeout, :unauthorized, :service_unavailable, :git_failed],
       do: reason

  defp failure_reason(_), do: :unknown

  defp remove(repo) do
    with {:ok, _} <- Client.request(:delete, repo.id),
         {:ok, _} <-
           Ledger.transaction(
             fn ->
               Ledger.create!(AuditEvent, :record, %{repository_id: repo.id, kind: :removed})

               repo
               |> Ash.Changeset.for_destroy(:remove, %{}, actor: SystemActor.compute())
               |> Ash.destroy!()
             end,
             :system
           ) do
      Marshall.Events.emit("enrico.remove_succeeded", repository_id: repo.id)
      :ok
    else
      _ -> {:error, :remove_failed}
    end
  end
end
