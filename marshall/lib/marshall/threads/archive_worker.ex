defmodule Marshall.Threads.ArchiveWorker do
  @moduledoc "Completes thread archival after Compute confirms physical deletion."
  use Oban.Worker,
    queue: :provisioning,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:thread_id, :machine_key],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Marshall.Compute.Ledger
  alias Marshall.Threads.Thread

  @impl true
  @spec perform(Oban.Job.t()) ::
          :ok | {:error, term()} | {:snooze, pos_integer()} | {:cancel, :invalid_job}
  def perform(%Oban.Job{args: %{"thread_id" => thread_id, "machine_key" => machine_key}})
      when is_binary(thread_id) and is_binary(machine_key) and byte_size(machine_key) > 0 do
    case Ledger.transaction(
           fn ->
             case Ledger.lock_history!(Thread, thread_id) do
               %Thread{status: :deleting} = current ->
                 if machine_key == current.machine_key do
                   finish(current)
                 else
                   :ok
                 end

               _ ->
                 :ok
             end
           end,
           {:system, nil}
         ) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_job}

  @spec finish(Thread.t()) :: :ok | {:snooze, pos_integer()}
  defp finish(%Thread{machine_id: nil} = thread), do: archive(thread)

  defp finish(thread) do
    case Ledger.history!(Marshall.Compute.VirtualMachine, id: thread.machine_id) do
      [%{archived_at: archived_at}] when not is_nil(archived_at) -> archive(thread)
      _ -> {:snooze, 5}
    end
  end

  @spec archive(Thread.t()) :: :ok
  defp archive(thread) do
    Ledger.update!(thread, :mark_archived, %{
      status: :archived,
      archived_at: DateTime.utc_now()
    })

    :ok
  end
end
