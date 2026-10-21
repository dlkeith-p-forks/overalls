defmodule Porsche.Events do
  @moduledoc """
  Catalog of reviewed structured-log events under ADR-0042.

  Porsche processes tagged `porsche_private: true` have every diagnostic
  redacted to a fixed category by `Porsche.Privacy`; the reviewed events in
  this catalog are the only informative exceptions, reconstructed from fixed
  text with validated correlation metadata. Metadata carries no peer
  identities, commands, fingerprints or credentials; there is deliberately no
  string-valued metadata type.
  """

  # @cc [owner:ghuntley,label:security] porsche-structured-events-through-catalog
  # Production Porsche modules MUST emit informative structured events only
  # through Porsche.Events.emit/2 with catalogued names and metadata keys, and
  # Porsche.Privacy MUST pass through only these reviewed events. Peer
  # identities, commands, key fingerprints and credentials MUST NOT appear in
  # event metadata.
  use Overalls.Diagnostics.Events.Catalog, service: :porsche

  defevent("porsche.authenticated", message: "SSH public key authentication proved", metadata: [])

  defevent("porsche.auth_denied",
    level: :warning,
    message: "SSH authentication denied",
    metadata: [reason: {:enum, [:invalid, :unknown_key]}]
  )

  defevent("porsche.session_outcome",
    message: "Marshall session open outcome",
    metadata: [outcome_state: :atom]
  )

  defevent("porsche.session_closed",
    message: "Marshall session closed",
    metadata: []
  )

  defevent("porsche.session_close_failed",
    level: :warning,
    message: "Marshall session close unconfirmed",
    metadata: []
  )

  defevent("porsche.exchange_failed",
    level: :warning,
    message: "Marshall HTTPS exchange failed",
    metadata: [reason: :atom]
  )

  defevent("porsche.command_unavailable",
    level: :warning,
    message: "SSH command dispatch unavailable",
    metadata: [reason: :atom]
  )

  defevent("porsche.terminal_attached",
    message: "SSH terminal attachment established",
    metadata: [mode: {:enum, [:rw, :ro]}]
  )

  defevent("porsche.terminal_detached",
    message: "SSH terminal attachment ended",
    metadata: [reason: {:enum, [:closed, :refused, :invalid, :authority, :transport, :client]}]
  )

  defevent("porsche.watch_opened",
    message: "SSH watch stream opened",
    metadata: [machines: :int64, threads: :int64, session: {:enum, [:watched, :unwatched]}]
  )

  defevent("porsche.watch_closed",
    message: "SSH watch stream closed",
    metadata: [reason: {:enum, [:closed, :revoked, :refused, :unavailable, :approval_expired]}]
  )

  defevent("porsche.stdin_payload_rejected",
    level: :warning,
    message: "SSH stdin payload rejected",
    metadata: [reason: {:enum, [:too_large, :invalid]}]
  )

  defevent("porsche.listener_lost",
    level: :warning,
    message: "SSH listener lost",
    metadata: [reason: :atom]
  )

  defevent("porsche.runtime_metrics",
    message: "Runtime metrics observed",
    metadata: [
      http_count: {:int64, :optional},
      http_duration_us: {:int64, :optional},
      http_errors: {:int64, :optional},
      ssh_count: {:int64, :optional},
      ssh_duration_us: {:int64, :optional},
      ssh_errors: {:int64, :optional},
      ssh_candidate_total: {:int64, :optional},
      ssh_proved_total: {:int64, :optional},
      beam_memory_bytes: {:int64, :optional},
      beam_processes: {:int64, :optional},
      beam_atoms: {:int64, :optional},
      beam_run_queue: {:int64, :optional}
    ]
  )

  defevent("porsche.slo_publication_failed",
    level: :warning,
    message: "SLO snapshot publication unavailable",
    metadata: []
  )

  defevent("porsche.slo_publication_recovered",
    message: "SLO snapshot publication recovered",
    metadata: []
  )

  defevent("porsche.observability_health",
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
