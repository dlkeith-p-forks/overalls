defmodule Marshall.Redaction do
  @moduledoc "Domain API for bounded, inactive-thread historical text scrubs."
  use Ash.Domain, otp_app: :marshall

  resources do
    resource(Marshall.Redaction.Run)
    resource(Marshall.Redaction.Shard)
  end

  @type scope :: :all_inactive | {:thread, String.t()}

  @spec enqueue(scope(), Marshall.Accounts.User.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def enqueue(scope, actor) when scope == :all_inactive or is_tuple(scope) do
    id = Ash.UUID.generate()
    effective_actor = actor || Marshall.Authorization.SystemActor.compute()

    with {:ok, _} <- Marshall.Redaction.Run.create(id, scope, effective_actor),
         :ok <- record_admin_audit(id, actor),
         {:ok, _job} <-
           %{"run_id" => id}
           |> Marshall.Redaction.Coordinator.new()
           |> Oban.insert() do
      {:ok, id}
    end
  end

  defp record_admin_audit(_id, nil), do: :ok

  defp record_admin_audit(id, %Marshall.Accounts.User{id: actor_id}) do
    case Ash.create(
           Marshall.Administration.AuditEvent,
           %{
             actor_id: actor_id,
             request_id: id,
             action: :redaction_requested,
             resource_type: :redaction,
             resource_id: id
           }, actor: Marshall.Authorization.SystemActor.compute()) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end