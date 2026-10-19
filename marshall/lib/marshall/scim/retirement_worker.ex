defmodule Marshall.Scim.RetirementWorker do
  @moduledoc "Durably advances SCIM identity retirement after its grace period."
  use Oban.Worker, queue: :maintenance, max_attempts: 10

  alias Marshall.Accounts.{User, UserDeletion}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  require Ash.Query

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    User
    |> Ash.Query.filter(active == false and scim_retirement_deadline <= ^now)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.each(&retire/1)

    :ok
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
