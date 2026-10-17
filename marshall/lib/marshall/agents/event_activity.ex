defmodule Marshall.Agents.EventActivity do
  @moduledoc "Queues the high-level thread activity projection after event append."
  use Ash.Resource.Change

  alias Marshall.Compute.Ledger

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), map()) :: Ash.Changeset.t()
  def change(changeset, _options, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      project_after_commit(event.thread_id)
      {:ok, event}
    end)
  end

  @impl true
  @spec atomic(Ash.Changeset.t(), keyword(), map()) :: {:ok, Ash.Changeset.t()}
  def atomic(changeset, options, context), do: {:ok, change(changeset, options, context)}

  @spec project_after_commit(String.t()) :: :ok
  defp project_after_commit(agent_thread_id) do
    callback = fn -> Marshall.Threads.Activity.touch_agent_thread(agent_thread_id) end

    if Process.get({Ledger, :transaction_depth}, 0) > 0,
      do: Ledger.after_commit(callback),
      else: callback.()

    :ok
  end
end
