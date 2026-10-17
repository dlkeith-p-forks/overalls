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

  @tag obligation: "lilly.transfer_clone.I3"
  test "export request grammar is exact and shell inert" do
    relocation = Lilly.UUID.generate()

    assert {:ok, %{relocation_id: ^relocation}} =
             Lilly.Transfer.ExportRequest.parse("lilly-export-v4 " <> relocation)

    refute match?({:ok, _}, Lilly.Transfer.ExportRequest.parse("lilly-export-v4  " <> relocation))

    assert {:error, :export_permit_unconfirmed} =
             Lilly.Transfer.ExportRequest.parse("lilly-export-v4 " <> relocation <> ";id")

    assert Lilly.Transfer.ExportRequest.token?("1-abc-def-01")
    refute Lilly.Transfer.ExportRequest.token?(String.duplicate("a", 8193))
  end
end
