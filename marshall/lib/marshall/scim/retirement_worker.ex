defmodule Marshall.Scim.RetirementWorker do
  @moduledoc "Durably advances SCIM identity retirement after its grace period."
  use Oban.Worker, queue: :maintenance, max_attempts: 10

  alias Marshall.Accounts.{User, UserDeletion}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, Lifecycle, VirtualMachine}
  require Ash.Query

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    pause_inactive_machines()

    User
    |> Ash.Query.filter(active == false and scim_retirement_deadline <= ^now)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.each(&retire/1)

    :ok
  end

  defp pause_inactive_machines do
    User
    |> Ash.Query.filter(active == false and is_nil(deleted_at))
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.each(fn user ->
      VirtualMachine
      |> Ash.Query.filter(owner_id == ^user.id and desired_state == :running)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.each(fn vm ->
        _ = Lifecycle.pause_for_scim(user.id, vm.id, "scim-pause:#{user.id}:#{vm.id}")
      end)
    end)
  end

  defp retire(user) do
    case UserDeletion
         |> Ash.Query.filter(user_id == ^user.id)
         |> Ash.read_one(actor: SystemActor.compute()) do
      {:ok, nil} ->
        Ledger.create!(UserDeletion, :record, %{
          user_id: user.id,
          requested_by_id: user.id,
          email: user.email
        })

      _ ->
        :ok
    end
  end
end
