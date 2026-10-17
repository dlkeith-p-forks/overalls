defmodule Galileo.Events do
  @moduledoc """
  Catalog of reviewed structured-log events under ADR-0042.

  Galileo modules emit events through `Galileo.Events.emit/2`, which the
  shared catalog machinery validates at caller compile time (event
  name and metadata keys) and at runtime (UUID, fixed-atom and bounded
  integer shapes). Message text is fixed here; call sites never interpolate
  payloads. Injected credentials, target URLs, request bodies and response
  content must never be passed as event metadata; there is deliberately no
  string-valued metadata type.
  """

  # @cc [owner:ghuntley,label:security] galileo-structured-events-through-catalog
  # Production Galileo modules MUST emit diagnostic structured events only
  # through Galileo.Events.emit/2 with catalogued names and metadata keys.
  # Injected credentials, upstream content and target origins MUST NOT be
  # passed as event metadata under any event.
  use Overalls.Diagnostics.Events.Catalog, service: :galileo

  defevent("galileo.request_authorized",
    message: "Integration request authorized",
    metadata: [host_id: {:uuid, :optional}, vm_id: {:uuid, :optional}]
  )

  defevent("galileo.request_denied",
    level: :warning,
    message: "Integration request denied",
    metadata: [host_id: {:uuid, :optional}, vm_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("galileo.upstream_outcome",
    message: "Upstream integration outcome",
    metadata: [host_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("galileo.control_exchange_failed",
    level: :warning,
    message: "Control exchange failed",
    metadata: [host_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("galileo.lease_renewal",
    message: "Integration lease renewal outcome",
    metadata: [host_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("galileo.control_version_refused",
    level: :error,
    message: "Control API version refused",
    metadata: [reason: :atom]
  )

  defevent("galileo.startup_configuration_rejected",
    level: :error,
    message: "Startup configuration rejected",
    metadata: [reason: :atom]
  )

  defevent("galileo.observability_health",
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
