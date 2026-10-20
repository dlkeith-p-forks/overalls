defmodule Marshall.Accounts.Login do
  @moduledoc "Fresh stored-login checks for long-lived user connections."
  alias AshAuthentication.{Jwt, TokenResource.Actions}
  alias Marshall.Accounts.{Token, User}
  alias Marshall.Authorization.SystemActor
  require Ash.Query

  # @cc [owner:ghuntley,label:security] login-user-purpose-and-subject
  # Verification MUST reject action tokens and tokens for another user even when
  # their signature is valid. Success requires a current active user and stored
  # user-token presence, independently of passkey enrollment or verification.
  # It returns the database-checked expiry; failure MUST NOT return token details.
  @spec verify(term(), User.t()) :: {:ok, binary(), DateTime.t()} | :error
  def verify(token, %User{} = user) when is_binary(token) do
    with {:ok, %{"sub" => subject, "jti" => jti} = claims, User} <- Jwt.verify(token, User),
         false <- Map.has_key?(claims, "act"),
         true <- subject == AshAuthentication.user_to_subject(user),
         {:ok, expires_at} <- token_present(jti, user.id) do
      {:ok, jti, expires_at}
    else
      _ -> :error
    end
  end

  def verify(_, _), do: :error

  # @cc [owner:ghuntley,label:security] login-no-revocation-cache
  # Each presence check MUST read the current user-purpose token for this JTI,
  # bind its subject to user_id and require expiry strictly after database time.
  # Previously accepted tokens MUST NOT remain authorized after removal, expiry
  # or account retirement. Passkey enrollment and elevation MUST NOT gate login.
  @spec present(binary(), String.t()) :: {:ok, DateTime.t()} | :error
  def present(jti, user_id) do
    case lookup(jti, user_id) do
      {:ok, expiry} -> {:ok, expiry}
      _ -> :error
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] login-check-distinguishes-unavailable
  # check/2 and token_check/2 MUST return :refused only for a definite answer
  # (missing, foreign or expired login) and :unavailable when the
  # lookup itself failed or raised; :unavailable never authorizes (ADR-0140).
  # present/2 and token_present/2 keep raising on an unreachable database.
  @doc "Fresh login check that separates a refusal from an unanswered lookup."
  @spec check(binary(), String.t()) :: {:ok, DateTime.t()} | :refused | :unavailable
  def check(jti, user_id) do
    lookup(jti, user_id)
  rescue
    _ -> :unavailable
  end

  @spec token_present(binary(), String.t()) :: {:ok, DateTime.t()} | :error
  def token_present(jti, user_id) do
    case token_lookup(jti, user_id) do
      {:ok, expiry} -> {:ok, expiry}
      _ -> :error
    end
  end

  @doc "Stored user-token presence, separating a refusal from an unanswered lookup."
  @spec token_check(binary(), String.t()) :: {:ok, DateTime.t()} | :refused | :unavailable
  def token_check(jti, user_id) do
    token_lookup(jti, user_id)
  rescue
    _ -> :unavailable
  end

  @spec lookup(binary(), String.t()) :: {:ok, DateTime.t()} | :refused | :unavailable
  defp lookup(jti, user_id), do: token_lookup(jti, user_id)

  @spec token_lookup(binary(), String.t()) :: {:ok, DateTime.t()} | :refused | :unavailable
  defp token_lookup(jti, user_id) do
    case Actions.get_token(Token, %{"jti" => jti, "purpose" => "user"}) do
      {:ok, [token]} ->
        if token.subject == AshAuthentication.user_to_subject(%User{id: user_id}) and
             active_user?(user_id) and
             DateTime.compare(token.expires_at, database_now()) == :gt,
           do: {:ok, token.expires_at},
           else: :refused

      {:ok, _} ->
        :refused

      {:error, _} ->
        :unavailable
    end
  end

  @spec active_user?(String.t()) :: boolean()
  defp active_user?(user_id) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^user_id and is_nil(deleted_at) and active == true)
    |> Ash.exists?()
  end

  defp database_now do
    %{rows: [[now]]} =
      Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT clock_timestamp()", [], log: false)

    now
  end
end
