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

  @tag obligation: "overalls_request_accounting.recorder.I3"
  test "recorder replies are closed and bounded" do
    assert :ok = Overalls.RequestAccounting.RecorderRPC.decode(~s({"status":"ok"}))

    assert {:admitted, 4} =
             Overalls.RequestAccounting.RecorderRPC.decode(~s({"status":"admitted","id":4}))

    assert {:error, :refused} =
             Overalls.RequestAccounting.RecorderRPC.decode(
               ~s({"status":"refused","reason":"schema"})
             )

    assert {:error, :unavailable} =
             Overalls.RequestAccounting.RecorderRPC.decode(~s({"status":"admitted","id":0}))

    assert {:error, :unavailable} = Overalls.RequestAccounting.RecorderRPC.decode("not-json")

    assert {:error, :unavailable} =
             Overalls.RequestAccounting.RecorderRPC.decode(String.duplicate("x", 513))
  end

  @tag obligation: "overalls_request_accounting.recorder.I4"
  test "producer admission and malformed completion fail closed" do
    assert :unrecorded = Overalls.RequestAccounting.Producer.admit(:missing_producer)
    assert :unrecorded = Overalls.RequestAccounting.Producer.admit(:missing_producer, self())

    assert :ok =
             Overalls.RequestAccounting.Producer.complete(
               :missing_producer,
               :bad_ticket,
               :success,
               1
             )

    assert :ok =
             Overalls.RequestAccounting.Producer.complete(
               :missing_producer,
               :unrecorded,
               :success,
               1
             )
  end
end
