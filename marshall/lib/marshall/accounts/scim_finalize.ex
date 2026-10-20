defmodule Marshall.Accounts.ScimFinalize do
  @moduledoc "Finalizes an expired SCIM retirement without changing the user UUID."
  alias Marshall.Accounts.{AccountLifecycle, ScimRetirement, UserDeletion}
  alias Marshall.Compute.Ledger

  # @cc [owner:ghuntley,label:security;recovery] scim-finalize-ghost-identity
  # Finalization MUST keep the UUID and history, archive the user's threads,
  # retire identity attachments, revoke every stored login, clear the OIDC
  # subject binding and replace the email with deleted-<uuid>@deleted.invalid
  # in one transaction. A finalized identity MUST NOT be changed again.
  @doc """
  Retires the identity of a completed `:scim_retirement` deletion. Administrator
  deletions retired their identity when they were recorded; for them, and for
  an identity that is already retired, this is a no-op. Requires the caller's
  transaction (DeleteUserMachines holds the retirement fence and deletion lock).
  """
  @spec finalize!(UserDeletion.t()) :: :ok
  def finalize!(%UserDeletion{kind: :scim_retirement, user_id: user_id}) do
    unless Marshall.Repo.in_transaction?(),
      do: raise(ArgumentError, "SCIM finalization requires the deletion transaction")

    user = ScimRetirement.lock_user!(user_id)

    if user && is_nil(user.deleted_at) do
      archive_threads!(user.id)
      AccountLifecycle.retire_attachments!(user.id, user.id)
      AccountLifecycle.revoke_tokens!(user.id)

      Ledger.update!(user, :scim_finalize, %{
        deleted_at: Ledger.now(),
        administrator: false,
        active: false,
        scim_external_id: nil,
        email: "deleted-#{user.id}@deleted.invalid",
        mfa_generation: user.mfa_generation + 1
      })
    end

    :ok
  end

  def finalize!(%UserDeletion{}), do: :ok

  @spec archive_threads!(String.t()) :: :ok
  defp archive_threads!(user_id) do
    now = Ledger.now()

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      """
      INSERT INTO scim_thread_archive_projections
        (id, thread_id, creator_id, title, objective, archived_at, reason, inserted_at, updated_at)
      SELECT gen_random_uuid(), id, creator_id, title, objective, $2, 'scim_retirement', $2, $2
      FROM threads
      WHERE creator_id = $1
      ON CONFLICT (thread_id) DO NOTHING
      """,
      [Ecto.UUID.dump!(user_id), now],
      log: false
    )

    :ok
  end
end
