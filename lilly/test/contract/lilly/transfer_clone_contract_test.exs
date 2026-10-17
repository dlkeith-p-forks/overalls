defmodule LillyTransferCloneContractTest do
  use Covenant.Case, component: "lilly.transfer_clone"

  @tag obligation: "lilly.transfer_clone.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Lilly.Clone.Effects,
      Lilly.Clone.Reason,
      Lilly.Clone.Runtime,
      Lilly.Transfer.CloneCopy,
      Lilly.Transfer.CloneCopyJournal,
      Lilly.Transfer.DestinationCleanup,
      Lilly.Transfer.DestinationRevocation,
      Lilly.Transfer.Endpoint,
      Lilly.Transfer.ExportRequest,
      Lilly.Transfer.Exporter,
      Lilly.Transfer.ImportCleanup,
      Lilly.Transfer.ImportJournal,
      Lilly.Transfer.Importer,
      Lilly.Transfer.Key,
      Lilly.Transfer.KeyRuntime,
      Lilly.Transfer.Permit,
      Lilly.Transfer.PermitJournal,
      Lilly.Transfer.Probe,
      Lilly.Transfer.ProbeRequest,
      Lilly.Transfer.ReadinessProbe,
      Lilly.Transfer.ReceiveRuntime,
      Lilly.Transfer.ReceivedDataset,
      Lilly.Transfer.Receiver,
      Lilly.Transfer.ResumeToken,
      Lilly.Transfer.SSH,
      Lilly.Transfer.SnapshotIndex,
      Lilly.Transfer.SnapshotJournal,
      Lilly.Transfer.SnapshotOwnership,
      Lilly.Transfer.Source,
      Lilly.Transfer.SourceCleanup,
      Lilly.Transfer.SourceExport,
      Lilly.Transfer.SourceRevocation,
      Lilly.Transfer.SourceRuntime,
      Lilly.Transfer.SourceSnapshotCleanup,
      Lilly.Transfer.SourceSnapshots,
      Lilly.Transfer.Stream
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
