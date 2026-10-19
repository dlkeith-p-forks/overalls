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
end
