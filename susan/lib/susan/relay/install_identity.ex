defmodule Susan.Relay.InstallIdentity do
  @moduledoc """
  A Marshall install identity, known only by the SHA-256 fingerprint of its
  Ed25519 public key (trust on first use).

      unknown -> trusted -> rate_limited -> trusted
           \\         \\            \\
            +---------+------------+--> blocked -> trusted (operator unblock)

  A first verified poke creates the identity as `unknown`; its first admitted
  poke trusts it. Exhausting the install bucket moves it to `rate_limited`,
  and the next admitted poke recovers it. Only an operator blocks or unblocks.
  """
  use Ash.Resource,
    otp_app: :susan,
    domain: Susan.Relay,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine]

  postgres do
    table "install_identities"
    repo Susan.Repo
  end

  # @cc [owner:ghuntley,label:security] susan-install-identity-lifecycle
  # Install identities MUST follow unknown -> trusted <-> rate_limited, with
  # blocked reachable from every state and left only by operator unblock. A
  # blocked identity's pokes MUST be refused before any provider effect. The
  # identity MUST be keyed by public-key fingerprint only, with no source
  # address, deployment, token or key material.
  state_machine do
    state_attribute :state
    initial_states [:unknown]
    default_initial_state :unknown

    transitions do
      transition :trust, from: [:unknown], to: :trusted
      transition :rate_limit, from: [:unknown, :trusted], to: :rate_limited
      transition :recover, from: [:rate_limited], to: :trusted
      transition :block, from: [:unknown, :trusted, :rate_limited], to: :blocked
      transition :unblock, from: [:blocked], to: :trusted
    end
  end

  code_interface do
    define :first_seen, args: [:fingerprint]
    define :by_fingerprint, args: [:fingerprint], get?: true, not_found_error?: false
    define :trust
    define :rate_limit
    define :recover
    define :block
    define :unblock
  end

  actions do
    defaults [:read]

    create :first_seen do
      accept [:fingerprint]
    end

    read :by_fingerprint do
      argument :fingerprint, :string, allow_nil?: false
      filter expr(fingerprint == ^arg(:fingerprint))
    end

    update :trust do
      accept []
      require_atomic? false
      change transition_state(:trusted)
    end

    update :rate_limit do
      accept []
      require_atomic? false
      change transition_state(:rate_limited)
    end

    update :recover do
      accept []
      require_atomic? false
      change transition_state(:trusted)
    end

    update :block do
      accept []
      require_atomic? false
      change transition_state(:blocked)
    end

    update :unblock do
      accept []
      require_atomic? false
      change transition_state(:trusted)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :fingerprint, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    create_timestamp :first_seen_at
    update_timestamp :updated_at
  end

  identities do
    identity :fingerprint, [:fingerprint]
  end
end
