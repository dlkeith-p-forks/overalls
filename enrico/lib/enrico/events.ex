defmodule Enrico.Events do
  @moduledoc "Reviewed, payload-free diagnostic events for Git mirror operations."
  use Overalls.Diagnostics.Events.Catalog, service: :enrico

  defevent("enrico.request_failed",
    level: :error,
    message: "Git mirror request failed",
    metadata: [reason: {:enum, [:exception, :exit]}]
  )

  defevent("enrico.refresh_started",
    message: "Git mirror refresh started",
    metadata: [repository_id: :uuid, attempt_id: :uuid]
  )

  defevent("enrico.refresh_succeeded",
    message: "Git mirror refresh succeeded",
    metadata: [repository_id: :uuid, attempt_id: :uuid]
  )

  defevent("enrico.refresh_failed",
    level: :warning,
    message: "Git mirror refresh failed",
    metadata: [repository_id: :uuid, attempt_id: :uuid, reason: :atom]
  )

  defevent("enrico.remove_succeeded",
    message: "Git mirror removed",
    metadata: [repository_id: :uuid]
  )

  defevent("enrico.request_denied",
    level: :warning,
    message: "Git mirror request denied",
    metadata: [reason: :atom]
  )

  defevent("enrico.startup_rejected",
    level: :error,
    message: "Git mirror startup configuration rejected",
    metadata: [reason: :atom]
  )

  defevent("enrico.observability_health",
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
