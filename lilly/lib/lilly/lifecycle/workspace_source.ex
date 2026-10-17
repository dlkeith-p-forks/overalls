defmodule Lilly.Lifecycle.WorkspaceSource do
  @moduledoc "Boot-bound workspace source reference hand-off and confirmed guest acceptance (ADR-0128)."
  use Lilly.Lifecycle.Resource,
    initial: [:pending],
    edges: [
      pending: [:pending, :delivering],
      delivering: [:delivering, :delivered, :failed, :pending],
      delivered: [:delivered, :pending],
      failed: [:failed, :delivering, :pending]
    ]
end
