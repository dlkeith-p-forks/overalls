defmodule Lilly.ObservabilityTest do
  use ExUnit.Case, async: false

  test "aggregation counts real backoff measurements and ignores metadata" do
    if Process.whereis(Lilly.Observability) == nil, do: start_supervised!(Lilly.Observability)
    Lilly.Observability.snapshot()

    Lilly.Observability.observe(
      [:lilly, :control, :backoff],
      %{count: 1},
      %{status: 503, sql: "secret SQL", credential: "secret token", vm_id: "unbounded"},
      nil
    )

    snapshot = Lilly.Observability.snapshot()
    assert snapshot["control_errors_count"] == 1
    assert snapshot["control_errors_duration_ms"] == 0
    assert snapshot["control_errors_errors"] == 0
    assert Enum.all?(Map.values(snapshot), &is_number/1)
    refute inspect(snapshot) =~ "secret"
    refute Map.has_key?(Lilly.Observability.snapshot(), "control_errors_count")
  end

  def log(event, %{config: owner}) do
    send(owner, {:metric_event, event})
    :ok
  end

  test "retired metric-summary reports translate to a redacted category" do
    report = %{
      event: "metrics.summary",
      service: "lilly",
      interval_seconds: 60,
      metrics: %{"beam_processes" => 7}
    }

    assert {:ok, "OTP runtime_report (process data redacted)", _} =
             Lilly.OTPReports.translate(:debug, :info, :report, {:logger, report})
  end

  test "actual metric emission survives formatted logging and source handlers" do
    :ok = Lilly.OTPReports.install()
    if Process.whereis(Lilly.Observability) == nil, do: start_supervised!(Lilly.Observability)
    :ok = :logger.add_handler(:lilly_metric_test, __MODULE__, %{level: :all, config: self()})
    on_exit(fn -> :logger.remove_handler(:lilly_metric_test) end)

    output =
      ExUnit.CaptureLog.capture_log(
        [formatter: {LoggerJSON.Formatters.Basic, metadata: [:event, :beam_processes]}],
        fn ->
          send(Lilly.Observability, :report)
          :sys.get_state(Lilly.Observability)
        end
      )

    assert output =~ "Runtime metrics observed"
    assert output =~ "beam_processes"

    assert_receive {:metric_event,
                    %{meta: %{event: "lilly.runtime_metrics", beam_processes: processes}}}

    assert is_integer(processes) and processes > 0
  end
end
