defmodule Peach.Events do
  @moduledoc """
  Catalog of reviewed structured-log events under ADR-0042.

  Peach modules emit events through `Peach.Events.emit/2`. Projection
  contents, guest identity fields beyond validated UUIDs, binding headers and
  control credentials must never be passed as event metadata; there is
  deliberately no string-valued metadata type.
  """

  # @cc [owner:ghuntley,label:security] peach-structured-events-through-catalog
  # Production Peach modules MUST emit diagnostic structured events only
  # through Peach.Events.emit/2 with catalogued names and metadata keys.
  use Overalls.Diagnostics.Events.Catalog, service: :peach

  defevent("peach.request_served",
    message: "Reflection request served",
    metadata: [host_id: {:uuid, :optional}, vm_id: {:uuid, :optional}]
  )

  defevent("peach.request_refused",
    level: :warning,
    message: "Reflection request refused",
    metadata: [host_id: {:uuid, :optional}, vm_id: {:uuid, :optional}, reason: :atom]
  )

  defevent("peach.startup_configuration_rejected",
    level: :error,
    message: "Startup configuration rejected",
    metadata: [reason: :atom]
  )
end
