defmodule Marshall.Accounts.RememberedLogin do
  @moduledoc "Serialize persistent browser credential exchange with account revocation."
  use Ash.Resource.Preparation
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Authorization.SystemActor
  require Ash.Query

  # @cc [owner:ghuntley,label:security;concurrency] remember-exchange-account-lock
  # Remembered sign-in MUST hold the current account row lock through stored-token
  # revalidation and new login issuance. Revocation, reset and retirement using
  # that lock MUST NOT be followed by issuance from the invalidated credential.
  # This exchange MUST NOT manufacture primary-email or completed-MFA receipts.
  @impl true
  @spec prepare(Ash.Query.t(), keyword(), Ash.Resource.Preparation.Context.t()) :: Ash.Query.t()
  def prepare(query, _, _) do
    Ash.Query.before_action(query, fn query ->
      token = Ash.Query.get_argument(query, :token)

      with {:ok, %{"sub" => subject, "purpose" => "remember_me"}, User} <-
             AshAuthentication.Jwt.verify(token, User),
           {:ok, [{"id", id}]} <- AshAuthentication.subject_to_primary_key(subject, User) do
        # The declared read transaction encloses this first hook, upstream
        # stored-token revalidation and its after_action login issuance.
        Security.lock_user!(id)
        query
      else
        _ -> Ash.Query.add_error(query, Ash.Error.Forbidden.exception([]))
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;concurrency] signout-credential-lock-order
  # Sign-out MUST lock every valid remembered credential's account and its
  # current login account in sorted order before revocation. Missing or retired
  # identities MUST NOT prevent credential/cookie removal.
  @spec lock_credentials!([String.t()], [String.t()]) :: :ok
  def lock_credentials!(tokens, user_ids) do
    token_ids =
      for token <- tokens,
          {:ok, %{"sub" => subject, "purpose" => "remember_me"}, User} <- [
            AshAuthentication.Jwt.verify(token, User)
          ],
          {:ok, [{"id", id}]} <- [AshAuthentication.subject_to_primary_key(subject, User)],
          do: id

    (user_ids ++ token_ids)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn id ->
      User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!()
    end)

    :ok
  end
end
