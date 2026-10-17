defmodule Lilly.Lifecycle.Permit do
  @moduledoc "Probe/export authority with permanent revocation."
  use Lilly.Lifecycle.Resource,
    initial: [:unissued],
    edges: [
      unissued: [:unissued, :probing, :active, :revoked],
      probing: [:probing, :active, :revoked],
      active: [:active, :revoked],
      revoked: [:revoked]
    ]
end
