defmodule Marshall.Threads.Activity do
  @moduledoc "Projects durable agent events onto the user thread activity clock."

  alias Marshall.Compute.Ledger
  alias Marshall.Threads.Thread

  # @cc [owner:ghuntley,label:durability;product] user-thread-activity-clock
  # A durable event on an agent thread paired with a user thread MUST advance
  # that user thread's activity clock. The projection runs after the event's
  # transaction commits and serializes on the user thread row, so concurrent
  # event receipts cannot move `updated_at` backwards or deadlock admission.
  @spec touch_agent_thread(String.t()) :: :ok
  def touch_agent_thread(agent_thread_id) when is_binary(agent_thread_id) do
    Ledger.transaction(fn ->
      case Ledger.read!(Thread, agent_thread_id: agent_thread_id) do
        [%Thread{archived_at: nil, status: status} = thread]
        when status not in [:archived, :deleting] ->
          locked = Ledger.lock_history!(Thread, thread.id) || Ledger.rollback(:not_found)
          _ = Ledger.update!(locked, :touch_activity, %{})
          :ok

        _ ->
          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _reason} -> :ok
    end
  end

  def touch_agent_thread(_), do: :ok
end
