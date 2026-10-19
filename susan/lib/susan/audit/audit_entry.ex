defmodule Susan.Audit.AuditEntry do
  @moduledoc """
  One append-only, hash-chained audit row.

  The resource defines only `:append` and reads: there is no update or
  destroy action. The database refuses UPDATE and TRUNCATE outright and
  DELETE except for the retention prune (see the migration
  `*_audit_append_only.exs`). Each row's `digest` covers its fields and the
  previous row's digest, so removing or editing an interior row breaks
  `Susan.Audit.Chain.verify/1`.

  Rows hold no source address, provider token, push key, ciphertext, nonce or
  route: only the closed action and reason enums, the install fingerprint,
  key id, provider, outcome and Marshall's delivery id for correlation.
  """
  use Ash.Resource,
    otp_app: :susan,
    domain: Susan.Audit,
    data_layer: AshPostgres.DataLayer

  @actions [
    :key_issued,
    :key_rotated,
    :key_denylisted,
    :poke_accepted,
    :poke_rejected,
    :rate_limited,
    :provider_sent,
    :provider_failed,
    :provider_unregistered,
    :install_first_seen,
    :install_blocked,
    :prune,
    :admin
  ]
  @reasons [
    :unknown_key,
    :expired_key,
    :replayed,
    :stale,
    :install_blocked,
    :denylisted,
    :deployment_mismatch,
    :unregistered,
    :key,
    :install,
    :source,
    :global,
    :retry,
    :rejected,
    :unavailable,
    :operator,
    :abuse,
    :compromised,
    :audit_read,
    :audit_export,
    :audit_verify,
    :unblock,
    :retention
  ]

  @spec actions() :: [atom()]
  def actions, do: @actions

  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  postgres do
    table "audit_entries"
    repo Susan.Repo

    custom_indexes do
      index [:occurred_at]
    end
  end

  # @cc [owner:ghuntley,label:security;privacy] susan-audit-append-only
  # Audit entries MUST be appended only through Susan.Audit.append/1, which
  # serialises appends and chains each digest to its predecessor. The resource
  # MUST NOT define update or destroy actions; the database MUST refuse UPDATE
  # and TRUNCATE and permit DELETE only inside the audited retention prune for
  # rows older than 90 days. Rows MUST NOT contain addresses, tokens, keys,
  # ciphertext, nonces or routes.
  actions do
    defaults [:read]

    create :append do
      accept [
        :action,
        :reason,
        :install_fingerprint,
        :key_id,
        :provider,
        :outcome,
        :delivery_id,
        :keyring_id,
        :count,
        :occurred_at,
        :prev_digest,
        :digest
      ]
    end

    read :chronological do
      prepare build(sort: [seq: :asc])
    end
  end

  attributes do
    integer_primary_key :seq
    attribute :action, :atom, allow_nil?: false, public?: true, constraints: [one_of: @actions]
    attribute :reason, :atom, public?: true, constraints: [one_of: @reasons]

    attribute :install_fingerprint, :string,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :key_id, :uuid, public?: true
    attribute :provider, :atom, public?: true, constraints: [one_of: [:apns, :fcm]]

    attribute :outcome, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:ok, :refused, :failed]]

    attribute :delivery_id, :uuid, public?: true
    attribute :keyring_id, :integer, public?: true, constraints: [min: 1, max: 255]
    attribute :count, :integer, public?: true, constraints: [min: 0]
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :prev_digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]
  end
end
