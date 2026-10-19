defmodule Marshall.Accounts.ScimFinalize do
  @moduledoc "Finalizes an expired SCIM retirement without changing the user UUID."
  alias Marshall.Accounts.{User, UserDeletion}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  require Ash.Query

  @spec finalize!(UserDeletion.t()) :: :ok
  def finalize!(%UserDeletion{user_id: user_id}) do
    Ledger.transaction(
      fn ->
        user =
          User
          |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
          |> Ash.Query.filter(id == ^user_id)
          |> Ash.Query.lock(:for_update)
          |> Ash.read_one!(actor: SystemActor.compute())

        if user && is_nil(user.deleted_at) do
          archive_threads!(user.id)
          Marshall.Accounts.AccountLifecycle.revoke_tokens!(user.id)

          Ledger.update!(user, :security_state, %{
            deleted_at: Ledger.now(),
            administrator: false,
            active: false,
            email: "deleted-#{user.id}@deleted.invalid",
            mfa_generation: user.mfa_generation + 1
          })
        end

        :ok
      end,
      SystemActor.compute()
    )

    :ok
  end

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
      [user_id, now],
      log: false
    )

    :ok
  end
end
