defmodule LillyVmLifecycleContractTest do
  use Covenant.Case, component: "lilly.vm_lifecycle"

  @tag obligation: "lilly.vm_lifecycle.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Lilly.Lifecycle,
      Lilly.Lifecycle.BackupHistory,
      Lilly.Lifecycle.BackupSnapshot,
      Lilly.Lifecycle.CloneCopy,
      Lilly.Lifecycle.Dataset,
      Lilly.Lifecycle.Execution,
      Lilly.Lifecycle.GuestTrust,
      Lilly.Lifecycle.ImageTemplate,
      Lilly.Lifecycle.Import,
      Lilly.Lifecycle.Journal,
      Lilly.Lifecycle.Observability,
      Lilly.Lifecycle.Permit,
      Lilly.Lifecycle.Persist,
      Lilly.Lifecycle.Provisioning,
      Lilly.Lifecycle.PublicationDiagnostics,
      Lilly.Lifecycle.Resize,
      Lilly.Lifecycle.Resource,
      Lilly.Lifecycle.SnapshotPointer,
      Lilly.Lifecycle.SnapshotSet,
      Lilly.Lifecycle.WorkspaceSource,
      Lilly.VM.API,
      Lilly.VM.Actor,
      Lilly.VM.Boot,
      Lilly.VM.Config,
      Lilly.VM.Credentials,
      Lilly.VM.DeleteRetry,
      Lilly.VM.Disk,
      Lilly.VM.Driver,
      Lilly.VM.Executable,
      Lilly.VM.Executor,
      Lilly.VM.Flush,
      Lilly.VM.GuestTrust,
      Lilly.VM.InceptionExchange,
      Lilly.VM.Intent,
      Lilly.VM.Jail,
      Lilly.VM.Journal,
      Lilly.VM.Logging,
      Lilly.VM.Observation,
      Lilly.VM.Provisioning,
      Lilly.VM.Readiness,
      Lilly.VM.Spec,
      Lilly.VM.Unit,
      Lilly.VM.WorkloadBundle,
      Lilly.VM.WorkspaceSource
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
