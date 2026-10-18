defmodule Lilly.Lifecycle.Execution do
  @moduledoc "Placement execution attempts and confirmed physical observations."
  use Lilly.Lifecycle.Resource,
    initial: [:idle],
    edges: [
      pausing: [:pausing, :paused, :unknown, :stopping, :deleting, :resuming],
      paused: [:pausing, :paused, :resuming, :stopping, :deleting, :unknown],
      resuming: [:resuming, :running, :pausing, :stopping, :deleting, :unknown, :failed],
      idle: [
        :idle,
        :starting,
        :pausing,
        :resuming,
        :stopping,
        :deleting,
        :resizing
      ],
      starting: [
        :starting,
        :pausing,
        :resuming,
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
        :pausing,
        :resuming,
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
        :pausing,
        :resuming,
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
        :pausing,
        :resuming,
        :stopping,
        :deleting,
        :resizing,
        :running,
        :stopped,
        :failed,
        :unknown,
        :deleted
      ],
      resizing: [
        :starting,
        :pausing,
        :resuming,
        :stopping,
        :deleting,
        :resizing,
        :stopped,
        :failed,
        :unknown
      ],
      deleting: [:deleting, :running, :stopped, :deleted, :failed, :unknown],
      failed: [
        :starting,
        :pausing,
        :resuming,
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
        :pausing,
        :resuming,
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
