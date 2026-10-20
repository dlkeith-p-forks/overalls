defmodule Marshall.Scim.RetirementWorker do
  @moduledoc """
  Durably drives SCIM user retirement (`Marshall.Accounts.ScimRetirement`).

  A job with a `"user_id"` reconciles that user: suspend machines during the
  grace period, resume SCIM-suspended machines after reactivation, and delete
  machines and finalize the identity after the deadline. The argument-less cron
  sweep re-enqueues every user that still has retirement work, so a lost or
  exhausted job is always recovered.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 20

  alias Marshall.Accounts.ScimRetirement
  require Marshall.Events

  @pending_snooze_seconds 60

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) ::
          :ok | {:snooze, pos_integer()} | {:error, term()} | {:cancel, :invalid_user_id}
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) when is_binary(user_id) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id) do
      case ScimRetirement.reconcile(user_id) do
        {:ok, :pending} ->
          {:snooze, @pending_snooze_seconds}

        {:ok, _outcome} ->
          :ok

        {:error, error} ->
          Marshall.Events.emit("scim.user_retirement_failed",
            user_id: user_id,
            reason: reason(error)
          )

          {:error, error}
      end
    else
      :error -> {:cancel, :invalid_user_id}
    end
  end

  def perform(%Oban.Job{}) do
    Enum.each(ScimRetirement.pending_user_ids(), &ScimRetirement.enqueue!/1)
    :ok
  end

  @spec reason(term()) :: atom()
  defp reason(%Marshall.Compute.Error{reason: reason}) when is_atom(reason), do: reason

  defp reason(%Ash.Error.Invalid{errors: [%Marshall.Compute.Error{reason: reason} | _]})
       when is_atom(reason),
       do: reason

  defp reason(reason) when is_atom(reason), do: reason
  defp reason(_), do: :unknown
end
