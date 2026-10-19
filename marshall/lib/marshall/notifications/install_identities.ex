defmodule Marshall.Notifications.InstallIdentities do
  @moduledoc "Generates and loads the single Ed25519 install identity (ADR-0225)."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications.InstallIdentity
  alias OverallsProtocol.SusanPoke

  # @cc [owner:ghuntley,label:security;persistence] notification-install-identity
  # Exactly one install identity MUST exist per deployment. It is generated
  # from the system CSPRNG on first need under a transaction-scoped advisory
  # lock, its seed is Vault-encrypted at rest and excluded from default reads,
  # and only its public key may leave Marshall.
  @doc "Returns the install identity, generating it inside the caller's transaction if absent."
  @spec ensure!() :: InstallIdentity.t()
  def ensure! do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["notifications:install-identity"],
      log: false
    )

    case Ledger.read!(InstallIdentity) do
      [identity] ->
        identity

      [] ->
        seed = :crypto.strong_rand_bytes(32)

        Ledger.create!(InstallIdentity, :generate, %{
          seed: seed,
          public_key: SusanPoke.public_key(seed)
        })
    end
  end

  @doc "Loads the decrypted seed and public key, generating the identity if needed."
  @spec signer() :: {:ok, %{seed: <<_::256>>, public_key: String.t()}} | {:error, term()}
  def signer do
    Ledger.transaction(fn ->
      identity =
        ensure!()
        |> Ash.load!([:seed], actor: SystemActor.compute())

      %{seed: identity.seed, public_key: identity.public_key}
    end)
  end
end
