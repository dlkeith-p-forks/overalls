defmodule OverallsRequestAccountingRecorderContractTest do
  use Covenant.Case, component: "overalls_request_accounting.recorder"

  @tag obligation: "overalls_request_accounting.recorder.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Overalls.RequestAccounting.Config,
      Overalls.RequestAccounting.Producer,
      Overalls.RequestAccounting.Producer.Server,
      Overalls.RequestAccounting.QualityMarker,
      Overalls.RequestAccounting.RecorderRPC
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "overalls_request_accounting.recorder.I2"
  test "quality marker round trips only in a private directory" do
    dir = Path.join(System.tmp_dir!(), "covenant-quality-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    assert :ok = Overalls.RequestAccounting.QualityMarker.write(dir, :clean)
    assert {:ok, :clean} = Overalls.RequestAccounting.QualityMarker.read(dir)
  end
end
