defmodule Marshall.ThreadStateFixture do
  @moduledoc "Drives test threads only through their named status transitions."
  alias Marshall.Compute.Ledger
  alias Marshall.Threads.Thread

  @type binding :: %{
          optional(:machine_id) => Ecto.UUID.t(),
          optional(:agent_root_id) => Ecto.UUID.t() | nil,
          optional(:agent_thread_id) => Ecto.UUID.t() | nil
        }

  @doc "Admits a machine (when given), binds the agent identity and marks the thread ready."
  @spec ready!(Thread.t(), binding()) :: Thread.t()
  def ready!(%Thread{} = thread, binding) do
    thread
    |> provisioning!(binding)
    |> Ledger.update!(:mark_ready, %{})
  end

  @doc "Admits a machine (when given) and binds the agent identity without readiness."
  @spec provisioning!(Thread.t(), binding()) :: Thread.t()
  def provisioning!(%Thread{} = thread, binding) do
    thread
    |> admit(Map.get(binding, :machine_id))
    |> Ledger.update!(:bind_agent, Map.take(binding, [:agent_root_id, :agent_thread_id]))
  end

  @spec failed!(Thread.t(), atom()) :: Thread.t()
  def failed!(%Thread{} = thread, reason),
    do: Ledger.update!(thread, :mark_failed, %{failure_reason: reason})

  @spec deleting!(Thread.t()) :: Thread.t()
  def deleting!(%Thread{} = thread), do: Ledger.update!(thread, :mark_deleting, %{})

  @spec archived!(Thread.t()) :: Thread.t()
  def archived!(%Thread{status: :archived} = thread), do: thread
  def archived!(%Thread{} = thread), do: Ledger.update!(thread, :mark_archived, %{})

  @doc "Archives the thread if needed, then reopens it under a new machine key."
  @spec reopened!(Thread.t(), String.t()) :: Thread.t()
  def reopened!(%Thread{} = thread, machine_key) when is_binary(machine_key) do
    thread
    |> archived!()
    |> Ledger.update!(:reopen, %{machine_key: machine_key})
  end

  @spec admit(Thread.t(), Ecto.UUID.t() | nil) :: Thread.t()
  defp admit(thread, nil), do: thread

  defp admit(thread, machine_id),
    do: Ledger.update!(thread, :record_admitted_machine, %{machine_id: machine_id})
end
