defmodule Marshall.Redaction do
  @moduledoc "Domain API for bounded, inactive-thread historical text scrubs."
  use Ash.Domain, otp_app: :marshall
  alias Marshall.Compute.Ledger
  require Marshall.Events

  resources do
    resource Marshall.Redaction.Run
    resource Marshall.Redaction.Shard
  end

  @type scope :: :all_inactive | {:thread, String.t()}

  # @cc [owner:ghuntley,label:security;observability] redaction-admission-receipt
  # Run creation, administrative receipt and scheduling MUST commit together.
  # Refused admission MUST emit only a fixed diagnostic and generated run ID;
  # it MUST NOT grant additional authority or disclose scope or error payloads.
  @spec enqueue(scope(), Marshall.Accounts.User.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def enqueue(scope, actor) when scope == :all_inactive or is_tuple(scope) do
    id = Ash.UUID.generate()
    effective_actor = actor || Marshall.Authorization.SystemActor.compute()

    result =
      Ledger.transaction(
        fn ->
          with {:ok, _} <- Marshall.Redaction.Run.create(id, scope, effective_actor),
               :ok <- record_admin_audit(id, actor),
               {:ok, _job} <-
                 %{"run_id" => id}
                 |> Marshall.Redaction.Coordinator.new()
                 |> Oban.insert() do
            id
          else
            {:error, _reason} -> Ledger.rollback(:redaction_unavailable)
          end
        end,
        actor || :system
      )

    case result do
      {:ok, _} ->
        result

      {:error, _} ->
        Marshall.Events.emit("redaction.admission_unavailable", run_id: id)
        result
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
           },
           action: :record,
           actor: Marshall.Authorization.SystemActor.compute()
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
