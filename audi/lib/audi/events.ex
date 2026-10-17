defmodule Audi.Events do
  @moduledoc """
  Catalog of reviewed structured-log events under ADR-0042.

  Audi modules emit events through `Audi.Events.emit/2`, which the
  shared catalog machinery validates at caller compile time (event
  name and metadata keys) and at runtime (UUID, fixed-atom and bounded
  integer shapes). Message text is fixed here; call sites never interpolate
  payloads. Credentials, tokens, hostnames, labels, packet data, request or
  response content and SSH payloads must never be passed as event metadata;
  there is deliberately no string-valued metadata type.
  """

  # @cc [owner:ghuntley,label:security] audi-fixed-operational-events
  # Operational logs MUST use this finite vocabulary and only validated identity
  # fields. Caller message text, errors, URLs, headers, hostnames, labels and
  # credentials MUST never be rendered, including in process metadata inherited
  # from a request.
  use Overalls.Diagnostics.Events.Catalog, service: :audi

  defevent("audi.editor_admitted",
    message: "Editor stream admitted",
    metadata: [
      host_id: :uuid,
      vm_id: :uuid,
      placement_id: :uuid,
      session_id: :uuid,
      guest_account_id: :uuid,
      user_id: :uuid,
      execution_epoch: :int64,
      generation: :int64
    ]
  )

  defevent("audi.editor_closed",
    message: "Editor stream closed",
    metadata: [
      host_id: :uuid,
      vm_id: :uuid,
      placement_id: :uuid,
      session_id: :uuid,
      guest_account_id: :uuid,
      user_id: :uuid,
      execution_epoch: :int64,
      generation: :int64
    ]
  )

  defevent("audi.editor_revoked",
    message: "Editor stream authority lost",
    metadata: [
      host_id: :uuid,
      vm_id: :uuid,
      placement_id: :uuid,
      session_id: :uuid,
      guest_account_id: :uuid,
      user_id: :uuid,
      execution_epoch: :int64,
      generation: :int64
    ]
  )

  defevent("audi.editor_denied", message: "Editor request denied", metadata: [reason: :atom])
  defevent("audi.editor_login_started", message: "Editor sign-in started", metadata: [])
  defevent("audi.editor_login_redeemed", message: "Editor sign-in redeemed", metadata: [])
  defevent("audi.editor_assets_ready", message: "Editor assets acknowledged", metadata: [])

  defevent("audi.editor_assets_unavailable",
    message: "Editor assets unavailable",
    metadata: [reason: :atom]
  )

  defevent("audi.process_crash",
    level: :error,
    message: "Audi process failed",
    metadata: [component: {:atom, :optional}, phase: {:atom, :optional}]
  )

  defevent("audi.supervisor_report",
    level: :error,
    message: "Audi supervisor reported a child failure",
    metadata: [component: {:atom, :optional}, phase: {:atom, :optional}]
  )

  defevent("audi.ssh_open",
    message: "SSH stream opened",
    metadata: [
      host_id: :uuid,
      vm_id: :uuid,
      placement_id: :uuid,
      session_id: :uuid,
      execution_epoch: :int,
      generation: :int
    ]
  )

  defevent("audi.web_admitted",
    message: "Web stream admitted",
    metadata: [
      host_id: :uuid,
      vm_id: :uuid,
      placement_id: :uuid,
      session_id: :uuid,
      execution_epoch: :int,
      generation: :int
    ]
  )

  defevent("audi.web_closed",
    message: "Web stream closed",
    metadata: [
      host_id: :uuid,
      vm_id: :uuid,
      placement_id: :uuid,
      session_id: :uuid,
      execution_epoch: :int,
      generation: :int,
      reason: {:atom, :optional}
    ]
  )

  defevent("audi.web_revoked",
    message: "Web stream authority lost",
    metadata: [
      host_id: :uuid,
      vm_id: :uuid,
      placement_id: :uuid,
      session_id: :uuid,
      execution_epoch: :int,
      generation: :int
    ]
  )

  defevent("audi.nested_denied",
    level: :warning,
    message: "Nested service connection denied",
    metadata: [reason: :atom]
  )

  defevent("audi.nested_revoked",
    message: "Nested stream authority lost",
    metadata: [
      host_id: :uuid,
      vm_id: :uuid,
      placement_id: :uuid,
      session_id: :uuid,
      execution_epoch: :int,
      generation: :int
    ]
  )

  defevent("audi.websocket_upgraded",
    message: "WebSocket stream upgraded",
    metadata: [
      host_id: :uuid,
      vm_id: :uuid,
      placement_id: :uuid,
      session_id: :uuid,
      execution_epoch: :int,
      generation: :int
    ]
  )

  defevent("audi.dns_available", message: "DNS replica refresh recovered", metadata: [])

  defevent("audi.dns_unavailable", message: "DNS replica refresh unavailable", metadata: [])

  defevent("audi.control_exchange_failed",
    level: :warning,
    message: "Control exchange failed",
    metadata: [host_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("audi.control_version_refused",
    level: :warning,
    message: "Control version refused; automatic work halted",
    metadata: [owner: :atom]
  )

  defevent("audi.web_login_started", message: "Browser sign-in started", metadata: [])

  defevent("audi.web_login_redeemed", message: "Browser sign-in redeemed", metadata: [])

  defevent("audi.web_login_denied",
    level: :warning,
    message: "Browser sign-in denied",
    metadata: [reason: :atom]
  )

  defevent("audi.web_denied",
    level: :warning,
    message: "Web request denied",
    metadata: [reason: :atom]
  )

  defevent("audi.ssh_denied",
    level: :warning,
    message: "SSH request denied",
    metadata: [reason: :atom]
  )

  defevent("audi.stream_fenced",
    level: :warning,
    message: "Guest stream fenced by authority guard",
    metadata: [host_id: :uuid, vm_id: :uuid, reason: :atom]
  )

  defevent("audi.host_key_published", message: "Host key published", metadata: [host_id: :uuid])

  defevent("audi.host_key_publication_failed",
    level: :warning,
    message: "Host key publication failed",
    metadata: [host_id: :uuid, reason: :atom]
  )

  defevent("audi.fleet_certificate_ready",
    message: "Fleet wildcard certificate ready on gateway",
    metadata: [host_id: :uuid, generation: :int]
  )

  defevent("audi.fleet_certificate_unavailable",
    level: :warning,
    message: "Fleet wildcard certificate readiness lost",
    metadata: [host_id: :uuid]
  )

  defevent("audi.fleet_certificate_sync_failed",
    level: :warning,
    message: "Fleet wildcard certificate synchronization failed",
    metadata: [host_id: :uuid, reason: :atom]
  )

  defevent("audi.certificate_install_rejected",
    level: :warning,
    message: "Certificate installation rejected",
    metadata: [reason: :atom]
  )

  defevent("audi.private_request_fenced",
    level: :warning,
    message: "Private request fenced by execution guard",
    metadata: [
      vm_id: {:uuid, :optional},
      host_id: {:uuid, :optional},
      placement_id: {:uuid, :optional},
      reason: :atom
    ]
  )

  defevent("audi.private_request_denied",
    level: :warning,
    message: "Private request denied",
    metadata: [host_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("audi.dns_publish_rejected",
    level: :warning,
    message: "DNS snapshot publication rejected",
    metadata: [reason: :atom]
  )

  defevent("audi.dns_listener_failed",
    level: :error,
    message: "DNS listener failed",
    metadata: [reason: :atom]
  )

  defevent("audi.dns_overload",
    level: :warning,
    message: "DNS listener at capacity",
    metadata: []
  )

  defevent("audi.connector_failed",
    level: :warning,
    message: "Local connector open failed",
    metadata: [reason: :atom]
  )

  defevent("audi.ssh_listener_lost",
    level: :warning,
    message: "SSH listener lost",
    metadata: []
  )

  defevent("audi.startup_configuration_rejected",
    level: :error,
    message: "Startup configuration rejected",
    metadata: [reason: :atom]
  )

  @doc """
  Catalogued execution-binding metadata fields of a binding map, for call
  sites and tests that previously passed raw maps. Absent fields are
  omitted; present fields still undergo `emit/2` runtime validation.
  """
  @spec binding_fields(map()) :: [
          {:host_id | :vm_id | :placement_id | :session_id | :execution_epoch | :generation,
           term()}
        ]
  def binding_fields(binding) when is_map(binding) do
    [:host_id, :vm_id, :placement_id, :session_id, :execution_epoch, :generation]
    |> Enum.flat_map(fn key ->
      case Map.get(binding, key) do
        nil -> []
        value -> [{key, value}]
      end
    end)
  end

  defevent("audi.observability_health",
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
