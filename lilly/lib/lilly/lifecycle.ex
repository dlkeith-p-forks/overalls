defmodule Lilly.Lifecycle do
  @moduledoc "Host-local, OS-locked state machines; no control-plane database dependency."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Lilly.Lifecycle.Checkpoint)
    resource(Lilly.Lifecycle.BackupSnapshot)
    resource(Lilly.Lifecycle.SnapshotPointer)
    resource(Lilly.Lifecycle.Resize)
    resource(Lilly.Lifecycle.Execution)
    resource(Lilly.Lifecycle.GuestTrust)
    resource(Lilly.Lifecycle.Provisioning)
    resource(Lilly.Lifecycle.ImageTemplate)
    resource(Lilly.Lifecycle.WorkspaceSource)
    resource(Lilly.Lifecycle.Dataset)
    resource(Lilly.Lifecycle.SnapshotSet)
    resource(Lilly.Lifecycle.Import)
    resource(Lilly.Lifecycle.CloneCopy)
    resource(Lilly.Lifecycle.Permit)
  end
end
