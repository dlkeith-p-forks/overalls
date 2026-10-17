defmodule Lilly.Lifecycle.Execution do
  @moduledoc "Placement execution attempts and confirmed physical observations."
  use Lilly.Lifecycle.Resource,
    initial: [:idle],
    edges: [
      idle: [:idle, :starting, :stopping, :deleting, :resizing],
      starting: [
        :starting,
        :stopping,
        :deleting,
        :resizing,
        :running,
        :stopped,
        :failed,
        :unknown
      ],
      running: [
        :running,
        :starting,
        :stopping,
        :deleting,
        :resizing,
        :stopped,
        :failed,
        :unknown,
        :deleted
      ],
      stopping: [
        :starting,
        :stopping,
        :deleting,
        :resizing,
        :running,
        :stopped,
        :failed,
        :unknown
      ],
      stopped: [
        :starting,
        :stopping,
        :deleting,
        :resizing,
        :running,
        :stopped,
        :failed,
        :unknown,
        :deleted
      ],
      resizing: [:starting, :stopping, :deleting, :resizing, :stopped, :failed, :unknown],
      deleting: [:deleting, :running, :stopped, :deleted, :failed, :unknown],
      failed: [
        :starting,
        :stopping,
        :deleting,
        :resizing,
        :running,
        :stopped,
        :failed,
        :unknown,
        :deleted
      ],
      unknown: [
        :starting,
        :stopping,
        :deleting,
        :resizing,
        :running,
        :stopped,
        :failed,
        :unknown,
        :deleted
      ],
      deleted: [:deleted, :deleting]
    ]
end
