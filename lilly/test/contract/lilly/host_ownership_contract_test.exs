defmodule LillyHostOwnershipContractTest do
  use Covenant.Case, component: "lilly.host_ownership"

  @tag obligation: "lilly.host_ownership.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Lilly.Host.BackupSnapshot,
      Lilly.Host.Collector,
      Lilly.Host.Command,
      Lilly.Host.Counters,
      Lilly.Host.EmptyDirectory,
      Lilly.Host.Hostd,
      Lilly.Host.Identity,
      Lilly.Host.Image,
      Lilly.Host.ImageCatalog,
      Lilly.Host.ImagePrewarm,
      Lilly.Host.ImageTemplate,
      Lilly.Host.InceptionProof,
      Lilly.Host.Inventory,
      Lilly.Host.Lease,
      Lilly.Host.Limits,
      Lilly.Host.Lock,
      Lilly.Host.LockOrder,
      Lilly.Host.MountTable,
      Lilly.Host.Ownership,
      Lilly.Host.Paths,
      Lilly.Host.Pool,
      Lilly.Host.PoolQueue,
      Lilly.Host.PoolSnapshot,
      Lilly.Host.PrivateFiles,
      Lilly.Host.Privilege,
      Lilly.Host.Sockets,
      Lilly.Host.Storage,
      Lilly.Host.TemplateSteward,
      Lilly.Host.UIDReservation,
      Lilly.Host.Usage,
      Lilly.Host.ZFS,
      Lilly.Host.ZFSDataset,
      Lilly.Host.ZFSIO,
      Lilly.Host.ZFSNamespaceMounts,
      Lilly.VM.Disk,
      Lilly.VM.Driver
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
