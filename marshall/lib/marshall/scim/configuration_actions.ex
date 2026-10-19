defmodule Marshall.Scim.ConfigurationActions do
  @moduledoc "Administrator-only SCIM configuration mutations."
  use Ash.Resource.Actions.Implementation

  alias Marshall.Accounts.Security
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Scim.{Auth, Configuration}
  require Ash.Query
  require Marshall.Events

  @impl true
  @spec run(Ash.ActionInput.t(), keyword(), map()) :: {:ok, map()} | {:error, term()}
  def run(input, _opts, %{actor: actor}) do
    Ledger.transaction(
      fn ->
        Security.require_admin!(actor)
        enabled = input.arguments[:enabled]
        rotate? = input.arguments[:rotate_token]
        oidc = Map.take(input.arguments, [:oidc_issuer, :oidc_client_id, :oidc_client_secret])
        config = current!()
        token = if rotate? or is_nil(config), do: generate_token(), else: nil

        config =
          if config do
            if config.state == :enabled and not enabled do
              Ledger.update!(config, :disable, %{})
            else
              if config.state == :disabled and enabled do
                Ledger.update!(config, :enable, %{})
              else
                config
              end
            end
          else
            Ledger.create!(Configuration, :create, %{
              token_digest: Auth.digest(token || generate_token()),
              state: if(enabled, do: :enabled, else: :disabled),
              enabled_at: if(enabled, do: Ledger.now())
            })
          end

        if enabled and config.state == :enabled do
          Marshall.Scim.TeamRetirement.retire_native_teams!()
        end

        config =
          config
          |> Ash.Changeset.for_update(:rotate_token, oidc)
          |> Ash.update!(actor: actor)

        config =
          if is_binary(token) and not is_nil(config) do
            Ledger.update!(config, :rotate_token, %{token_digest: Auth.digest(token)})
          else
            config
          end

        enabled_state = if(config.state == :enabled, do: :enabled, else: :disabled)

        Ledger.after_commit(fn ->
          Marshall.Events.emit("scim.configuration_changed", enabled: enabled_state)
        end)

        %{enabled: config.state == :enabled, token: if(rotate?, do: token), oidc: oidc}
      end,
      actor
    )
  rescue
    error -> {:error, error}
  end

  defp current! do
    Configuration
    |> Ash.Query.filter(key == "installation")
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  defp generate_token do
    "scim_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end
end
