defmodule Marshall.Scim.ConfigurationActions do
  @moduledoc """
  Administrator-only SCIM configuration mutations.

  Each call performs exactly one operation. `:enable` and `:rotate_token`
  generate a bearer token, persist only its digest and return the plaintext
  once; `:disable` and `:save_oidc` never return a token. Saving OIDC settings
  keeps the stored client secret when the submitted secret is blank, unless the
  caller explicitly asks to clear it.
  """
  use Ash.Resource.Actions.Implementation

  alias Marshall.Accounts.Security
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Scim.{Auth, Configuration, Oidc}
  require Ash.Query
  require Marshall.Events

  @type operation :: :enable | :disable | :rotate_token | :save_oidc
  @type result :: %{enabled: boolean(), token: String.t() | nil}

  @impl true
  @spec run(Ash.ActionInput.t(), keyword(), map()) :: {:ok, result()} | {:error, term()}
  def run(input, _opts, %{actor: actor}) do
    operation = input.arguments[:operation]

    with {:ok, oidc} <- oidc_changes(operation, input.arguments) do
      Ledger.transaction(
        fn ->
          Security.require_admin!(actor)
          {config, token} = apply_operation(operation, current!(), oidc)
          enabled_state = if(config.state == :enabled, do: :enabled, else: :disabled)

          Ledger.after_commit(fn ->
            Marshall.Events.emit("scim.configuration_changed", enabled: enabled_state)
          end)

          %{enabled: config.state == :enabled, token: token}
        end,
        actor
      )
    end
  rescue
    error -> {:error, error}
  end

  @spec apply_operation(operation(), Configuration.t() | nil, map()) ::
          {Configuration.t(), String.t() | nil}
  defp apply_operation(:enable, nil, _oidc) do
    token = generate_token()

    config =
      Ledger.create!(Configuration, :create, %{
        token_digest: Auth.digest(token),
        state: :enabled,
        enabled_at: Ledger.now()
      })

    Marshall.Scim.TeamRetirement.retire_native_teams!()
    {config, token}
  end

  defp apply_operation(:enable, %Configuration{state: :disabled} = config, _oidc) do
    token = generate_token()
    config = Ledger.update!(config, :enable, %{})

    if config.state == :enabled do
      Marshall.Scim.TeamRetirement.retire_native_teams!()
    end

    {Ledger.update!(config, :rotate_token, %{token_digest: Auth.digest(token)}), token}
  end

  defp apply_operation(:disable, %Configuration{state: :enabled} = config, _oidc),
    do: {Ledger.update!(config, :disable, %{}), nil}

  defp apply_operation(:rotate_token, %Configuration{state: :enabled} = config, _oidc) do
    token = generate_token()
    {Ledger.update!(config, :rotate_token, %{token_digest: Auth.digest(token)}), token}
  end

  defp apply_operation(:save_oidc, nil, oidc) do
    config = Ledger.create!(Configuration, :create, %{state: :disabled})
    apply_operation(:save_oidc, config, oidc)
  end

  defp apply_operation(:save_oidc, %Configuration{} = config, oidc) do
    oidc =
      case oidc do
        %{oidc_client_secret: :keep} -> Map.delete(oidc, :oidc_client_secret)
        _ -> oidc
      end

    {Ledger.update!(config, :save_oidc, oidc), nil}
  end

  defp apply_operation(_operation, _config, _oidc), do: Ledger.rollback(:invalid_transition)

  @spec oidc_changes(operation() | nil, map()) :: {:ok, map()} | {:error, :invalid_oidc_issuer}
  defp oidc_changes(:save_oidc, arguments) do
    issuer = blank_to_nil(arguments[:oidc_issuer])
    client_id = blank_to_nil(arguments[:oidc_client_id])

    secret =
      cond do
        arguments[:clear_oidc_client_secret] == true -> nil
        is_nil(blank_to_nil(arguments[:oidc_client_secret])) -> :keep
        true -> arguments[:oidc_client_secret]
      end

    if is_nil(issuer) or Oidc.valid_issuer?(issuer),
      do: {:ok, %{oidc_issuer: issuer, oidc_client_id: client_id, oidc_client_secret: secret}},
      else: {:error, :invalid_oidc_issuer}
  end

  defp oidc_changes(_operation, _arguments), do: {:ok, %{}}

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  @spec current!() :: Configuration.t() | nil
  defp current! do
    Configuration
    |> Ash.Query.filter(key == "installation")
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  @spec generate_token() :: String.t()
  defp generate_token do
    "scim_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end
end
