defmodule Susan.Events do
  @moduledoc """
  Catalog of reviewed structured-log events for the Susan push relay (ADR-0042,
  ADR-0224).

  Every Susan diagnostic goes through `Susan.Events.emit/2`. Metadata is closed
  enums and bounded integers only: there is deliberately no string type, so a
  source address, provider token, push key, ciphertext, route, nonce,
  signature or install key can never be passed as event metadata.
  """

  # @cc [owner:ghuntley,label:privacy;security] susan-structured-events-through-catalog
  # Production Susan modules MUST emit diagnostics only through Susan.Events.emit/2
  # with catalogued names and enum/integer metadata. Source addresses, provider
  # tokens, push keys, ciphertext, routes, nonces and install keys MUST NOT be
  # event metadata under any event.
  use Overalls.Diagnostics.Events.Catalog, service: :susan

  defevent("susan.key_issued",
    message: "Push key issued",
    metadata: [provider: {:enum, [:apns, :fcm]}, keyring_id: :int]
  )

  defevent("susan.key_refused",
    level: :warning,
    message: "Push key issuance refused",
    metadata: [reason: {:enum, [:malformed, :unregistered, :rate_limited, :unavailable]}]
  )

  defevent("susan.poke_accepted",
    message: "Poke accepted for delivery",
    metadata: [provider: {:enum, [:apns, :fcm]}, duplicate: {:enum, [:no, :yes]}]
  )

  defevent("susan.poke_rejected",
    level: :warning,
    message: "Poke rejected",
    metadata: [
      reason:
        {:enum,
         [
           :malformed,
           :unknown_key,
           :expired_key,
           :deployment_mismatch,
           :bad_signature,
           :install_blocked,
           :denylisted,
           :replayed,
           :stale,
           :in_flight,
           :unregistered
         ]}
    ]
  )

  defevent("susan.rate_limited",
    level: :warning,
    message: "Request rate limited",
    metadata: [
      scope: {:enum, [:key, :install, :source, :global]},
      retry_after: :int
    ]
  )

  defevent("susan.provider_outcome",
    message: "Push provider outcome",
    metadata: [
      provider: {:enum, [:apns, :fcm]},
      outcome: {:enum, [:sent, :unregistered, :retry, :rejected, :unavailable]},
      attempt: :int
    ]
  )

  defevent("susan.install_transition",
    message: "Install identity state changed",
    metadata: [to: {:enum, [:unknown, :trusted, :rate_limited, :blocked]}]
  )

  defevent("susan.audit_appended",
    trace: false,
    message: "Audit entry appended",
    metadata: [
      action:
        {:enum,
         [
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
         ]}
    ]
  )

  defevent("susan.audit_append_failed",
    level: :error,
    message: "Audit entry append failed",
    metadata: [
      action:
        {:enum,
         [
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
         ]}
    ]
  )

  defevent("susan.audit_pruned",
    message: "Audit retention prune completed",
    metadata: [count: :int]
  )

  defevent("susan.keyring_rotated",
    message: "Push key sealing keyring rotated",
    metadata: [keyring_id: :int]
  )

  defevent("susan.operator_action",
    message: "Operator action executed",
    metadata: [
      operation: {:enum, [:audit_read, :audit_export, :audit_verify, :denylist, :block, :unblock]}
    ]
  )

  defevent("susan.startup_configuration_rejected",
    level: :error,
    message: "Startup configuration rejected",
    metadata: [reason: {:enum, [:invalid_runtime_configuration]}]
  )

  defevent("susan.observability_health",
    trace: false,
    message: "Observability producer health observed",
    metadata: [
      trace_available: :int64,
      trace_pending: :int64,
      trace_queue_dropped: :int64,
      trace_export_failed: :int64
    ]
  )
end
