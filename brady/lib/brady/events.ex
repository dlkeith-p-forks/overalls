defmodule Brady.Events do
  @moduledoc """
  Catalog of reviewed structured-log events under ADR-0042.

  Brady modules emit events through `Brady.Events.emit/2`, which the
  shared catalog machinery validates at caller compile time (event
  name and metadata keys) and at runtime (fixed-atom and bounded integer
  shapes). Message text is fixed here; call sites never interpolate payloads.
  URLs, headers, bodies, certificates, keys, subject or host names, peer
  identities and terminal bytes must never be passed as event metadata; there
  is deliberately no string-valued metadata type.
  """

  # @cc [owner:ghuntley,label:security] brady-structured-events-through-catalog
  # Production Brady modules MUST emit diagnostic structured events only
  # through Brady.Events.emit/2 with catalogued names and metadata keys.
  # URLs, headers, bodies, certificates, keys, subject or host names, peer
  # identities and terminal bytes MUST NOT be passed as event metadata under
  # any event.
  use Overalls.Diagnostics.Events.Catalog, service: :brady

  defevent("brady.cache_pressure_paused",
    message: "Cache writes paused with confirmed mount custody",
    metadata: [reason: :atom]
  )

  defevent("brady.cache_pressure_resumed",
    message: "Cache capacity observations resumed",
    metadata: []
  )

  defevent("brady.cache_write_admitted",
    message: "Cache write admitted",
    metadata: [framing: :atom]
  )

  defevent("brady.cache_write_refused",
    message: "Cache write refused",
    metadata: [reason: :atom, observation_age_ms: :int, capacity_remaining_ms: :int]
  )

  defevent("brady.cache_write_finished",
    message: "Cache write finished",
    metadata: [outcome: :atom, payload_chunks: :int]
  )

  defevent("brady.cache_store_started",
    message: "Cache store started",
    metadata: []
  )

  defevent("brady.cache_store_lost",
    level: :warning,
    message: "Cache store lost",
    metadata: [reason: :atom]
  )

  defevent("brady.cache_custody_lost",
    level: :warning,
    message: "Cache custody lost",
    metadata: []
  )

  defevent("brady.listener_failed",
    level: :error,
    message: "Listener failed",
    metadata: [reason: :atom]
  )

  defevent("brady.listener_overload",
    level: :warning,
    message: "Listener at connection capacity",
    metadata: []
  )

  defevent("brady.metrics_publish_failed",
    level: :warning,
    message: "Metrics publish failed",
    metadata: [reason: :atom]
  )

  defevent("brady.certificate_signed",
    message: "Runtime CA leaf certificate signed",
    metadata: []
  )

  defevent("brady.configuration_rejected",
    level: :error,
    message: "Runtime configuration rejected",
    metadata: [reason: :atom]
  )

  defevent("brady.request_completed",
    message: "Request completed",
    metadata: [
      host_id: {:uuid, :optional},
      vm_id: {:uuid, :optional},
      placement_id: {:uuid, :optional},
      owner_id: {:uuid, :optional},
      request_id: {:uuid, :optional},
      execution_epoch: {:int64, :optional},
      generation: {:int64, :optional},
      status: {:int, :optional},
      port: {:int, :optional},
      bytes_received: {:int64, :optional},
      bytes_sent: {:int64, :optional},
      duration_us: {:int64, :optional},
      attribution: {{:enum, [:resolved, :unresolved]}, :optional},
      protocol: {{:enum, [:http, :https, :tunnel]}, :optional},
      cache: {{:enum, [:hit, :miss, :bypass, :failed]}, :optional},
      cache_write: {{:enum, [:published, :abandoned, :not_attempted]}, :optional},
      reason:
        {{:enum,
          [
            :ok,
            :policy,
            :upstream,
            :tls,
            :timeout,
            :capacity,
            :storage,
            :invalid_request,
            :invalid_http,
            :internal,
            :transport,
            :closed
          ]}, :optional},
      slo_admitted: {{:enum, [:yes]}, :optional},
      method:
        {{:enum, [:get, :head, :post, :put, :delete, :options, :patch, :connect, :trace]},
         :optional}
    ]
  )

  defevent("brady.observability_health",
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
