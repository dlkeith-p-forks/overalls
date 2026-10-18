defmodule Marshall.Compute.IdleWorker do
  @moduledoc "Durable periodic idle reconciliation; each candidate is independently rechecked."
  use Oban.Worker, queue: :provisioning, unique: [period: 60]
  alias Marshall.Compute.{Idle, Ledger, VirtualMachine}
  alias Marshall.Authorization.SystemActor
  require Ash.Query

  @impl true
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}), do: reconcile(nil)

  @spec reconcile(String.t() | nil) :: :ok
  defp reconcile(after_id) do
    query =
      VirtualMachine
      |> Ash.Query.filter(
        idle_suspend_enabled == true and desired_state == :running and observed_state == :running
      )
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(1_000)

    query = if after_id, do: Ash.Query.filter(query, id > ^after_id), else: query
    batch = Ash.read!(query, actor: SystemActor.compute())

    batch
    |> Enum.each(fn vm ->
      if Idle.due?(vm, Ledger.now()), do: Idle.suspend(vm.id)
    end)

    case List.last(batch) do
      nil -> :ok
      vm -> reconcile(vm.id)
    end
  end
end
