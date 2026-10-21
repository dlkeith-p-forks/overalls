defmodule Peach.PrivacyTest do
  use ExUnit.Case, async: false

  test "source filter protects additional handlers while preserving crash categories" do
    output =
      ExUnit.CaptureLog.capture_log([format: "$message $metadata", metadata: :all], fn ->
        :logger.log(
          :error,
          %{label: {:gen_server, :terminate}, state: "peach-private-canary"},
          %{credential: "peach-private-canary"}
        )
      end)

    assert output =~ "process_crash"
    refute output =~ "peach-private-canary"
  end

  test "projection stages are trace-only and producer health does not enqueue traces" do
    assert :stop =
             Peach.Privacy.filter(
               %{msg: {:string, "private"}, meta: %{event: "peach.projection_requested"}},
               nil
             )

    before = Overalls.Diagnostics.Processor.health().pending

    output =
      ExUnit.CaptureLog.capture_log(
        [formatter: {Overalls.Diagnostics.Formatter, [catalog: Peach.Events]}],
        fn -> assert :ok = Overalls.Diagnostics.Processor.publish_health(Peach.Events) end
      )

    assert %{
             "event" => "peach.observability_health",
             "metadata" => %{"trace_pending" => _, "trace_export_failed" => _}
           } = Jason.decode!(output)

    assert Overalls.Diagnostics.Processor.health().pending == before
  end
end
