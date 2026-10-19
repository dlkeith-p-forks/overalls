defmodule Marshall.Scim.Oidc do
  @moduledoc "Validates an already verified OIDC claim set against SCIM identity."
  require Ash.Query

  @type claims :: %{required(String.t()) => term()}

  @spec authenticate(claims()) :: {:ok, Marshall.Accounts.User.t()} | {:error, atom()}
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

  defp enabled_configuration do
    Marshall.Scim.Configuration
    |> Ash.Query.filter(state == :enabled)
    |> Ash.read_one(actor: Marshall.Authorization.SystemActor.compute())
    |> case do
      {:ok, nil} -> {:error, :scim_disabled}
      {:ok, config} when is_binary(config.oidc_issuer) -> {:ok, config}
      _ -> {:error, :oidc_not_configured}
    end
  end

  defp find_subject(subject) do
    Marshall.Accounts.User
    |> Ash.Query.filter(scim_external_id == ^subject)
    |> Ash.read_one(actor: Marshall.Authorization.SystemActor.compute())
    |> case do
      {:ok, nil} -> {:error, :unknown_oidc_subject}
      {:ok, user} -> {:ok, user}
      _ -> {:error, :unknown_oidc_subject}
    end
  end
end
