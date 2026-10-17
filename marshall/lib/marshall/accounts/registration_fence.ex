defmodule Marshall.Accounts.RegistrationFence do
  @moduledoc "Old emailed links cannot resurrect a retired account identity."
  use Ash.Resource.Change
  alias Marshall.Accounts.{User, UserDeletion, Token}
  alias Marshall.Authorization.SystemActor
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;concurrency] retired-email-token-fence
  # After the bootstrap/account latch is locked, magic-link consumption MUST
  # reject tokens issued before the latest retirement of that email. A new
  # registration gets a new UUID and MUST NOT inherit old credentials or grants.

  # @cc [owner:ghuntley,label:observability] retired-token-rejection-after-commit
  # The rejection event MUST be emitted only after the sign-in transaction rolls
  # back, and only for a token issued before the latest retirement of that
  # identity; unrelated invalid-token failures MUST NOT emit it.
  @impl true
  def change(changeset, _, _) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      token = Ash.Changeset.get_argument(changeset, :token)

      with {:ok, claims, User} <- AshAuthentication.Jwt.verify(token, User),
           {:ok, [stored]} <-
             AshAuthentication.TokenResource.Actions.get_token(Token, %{
               "jti" => claims["jti"],
               "purpose" => "magic_link"
             }) do
        email = claims["identity"]

        retired =
          UserDeletion
          |> Ash.Query.filter(email == ^email)
          |> Ash.Query.sort(inserted_at: :desc)
          |> Ash.Query.limit(1)
          |> Ash.read!(actor: SystemActor.compute())

        case retired do
          [record] ->
            if DateTime.compare(stored.created_at, record.inserted_at) == :gt,
              do: changeset,
              else: reject(changeset)

          [] ->
            changeset
        end
      else
        _ -> Ash.Changeset.add_error(changeset, "Request a new sign-in link.")
      end
    end)
    |> Ash.Changeset.after_transaction(fn _, result ->
      retired? = Process.get({__MODULE__, :retired_token_rejected}) == true
      _ = Process.delete({__MODULE__, :retired_token_rejected})

      if retired? and match?({:error, _}, result) and not Marshall.Repo.in_transaction?() do
        Marshall.Events.emit("auth.retired_token_rejected", [])
      end

      result
    end)
  end

  defp reject(changeset) do
    Process.put({__MODULE__, :retired_token_rejected}, true)
    Ash.Changeset.add_error(changeset, "Request a new sign-in link.")
  end
end
