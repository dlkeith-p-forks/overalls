defmodule Marshall.Scim.Oidc do
  @moduledoc "Runtime OIDC claim validation and session-token issuance for SCIM identities."
  require Ash.Query
  alias AshAuthentication.TokenResource.Actions
  alias Marshall.Accounts.{Token, User}
  alias Marshall.Authorization.SystemActor

  @type claims :: %{required(String.t()) => term()}
  @type error ::
          :invalid_oidc_claims
          | :scim_disabled
          | :oidc_not_configured
          | :oidc_claim_mismatch
          | :unknown_oidc_subject

  @spec authenticate(claims()) :: {:ok, User.t()} | {:error, error()}
  def authenticate(%{"iss" => issuer, "sub" => subject})
      when is_binary(issuer) and is_binary(subject) and subject != "" do
    with {:ok, config} <- enabled_configuration(),
         true <- config.oidc_issuer == issuer,
         {:ok, user} <- find_subject(subject),
         true <- user.active do
      {:ok, user}
    else
      false -> {:error, :oidc_claim_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :oidc_claim_mismatch}
    end
  end

  def authenticate(_), do: {:error, :invalid_oidc_claims}

  @doc "Validates verified provider claims and mints a stored browser login token."
  @spec sign_in(claims()) :: {:ok, User.t(), binary()} | {:error, error() | term()}
  def sign_in(claims) do
    with {:ok, user} <- authenticate(claims),
         {:ok, token, _claims} <- AshAuthentication.Jwt.token_for_user(user, %{"amr" => "oidc"}),
         :ok <-
           Actions.store_token(Token, %{"token" => token, "purpose" => "user"},
             context: %{private: %{ash_authentication?: true}}
           ) do
      {:ok, user, token}
    end
  end

  defp enabled_configuration do
    Marshall.Scim.Configuration
    |> Ash.Query.filter(state == :enabled)
    |> Ash.read_one(actor: SystemActor.compute())
    |> case do
      {:ok, nil} -> {:error, :scim_disabled}
      {:ok, config} when is_binary(config.oidc_issuer) -> {:ok, config}
      _ -> {:error, :oidc_not_configured}
    end
  end

  defp find_subject(subject) do
    User
    |> Ash.Query.filter(scim_external_id == ^subject)
    |> Ash.read_one(actor: SystemActor.compute())
    |> case do
      {:ok, nil} -> {:error, :unknown_oidc_subject}
      {:ok, user} -> {:ok, user}
      _ -> {:error, :unknown_oidc_subject}
    end
  end
end
