defmodule LillyTransferCloneBehaviorContractTest do
  use Covenant.Case, component: "lilly.transfer_clone"
  @tag obligation: "lilly.transfer_clone.I2"
  test "transfer keys reject invalid destinations without creating state" do
    dir = Path.join(System.tmp_dir!(), "lilly-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    assert {:error, _reason} = Lilly.Transfer.Key.ensure(dir, "bad", "bad", "bad")
    assert File.ls!(dir) == []
  end
end
