defmodule Porsche.ObservabilityTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias Porsche.Observability

  defmodule Handler do
    def log(event, %{config: owner}) do
      send(owner, {:metric_event, event})
      :ok
    end
  end

  setup do
    Observability.snapshot()
    :ok
  end

  property "aggregate counts match an independent model and discard arbitrary metadata" do
    check all(
            events <-
              list_of(
                tuple(
                  {member_of([:http, :ssh]), integer(0..1_000_000), integer(0..1),
                   binary(max_length: 128)}
                ),
                max_length: 100
              )
          ) do
      Observability.snapshot()

      expected =
        Enum.reduce(events, %{}, fn {kind, duration, error, secret}, model ->
          Observability.observe(
            [:porsche, kind, :complete],
            %{duration_us: duration, error: error},
            %{token: secret, command: secret},
            nil
          )

          Map.update(model, kind, {1, duration, error}, fn {n, d, e} ->
            {n + 1, d + duration, e + error}
          end)
        end)

      assert :ets.info(Observability, :size) <= 2
      snapshot = Observability.snapshot()

      for {kind, {count, duration, errors}} <- expected do
        assert snapshot["#{kind}_count"] == count
        assert snapshot["#{kind}_duration_ms"] == duration / 1000
        assert snapshot["#{kind}_errors"] == errors
      end

      assert Map.keys(Observability.snapshot()) |> Enum.sort() ==
               ~w(beam_atoms beam_memory_bytes beam_processes beam_run_queue ssh_candidate_total ssh_proved_total)
    end
  end

  test "ssh candidate and proved telemetry surface as clamped cumulative counters" do
    before = Observability.snapshot()

    Observability.observe([:porsche, :ssh, :candidate], %{count: 1}, %{token: "secret"}, nil)
    Observability.observe([:porsche, :ssh, :proved], %{count: 3}, %{}, nil)
    Observability.observe([:porsche, :ssh, :candidate], %{count: -5}, %{}, nil)
    Observability.observe([:porsche, :ssh, :candidate], %{count: "x"}, %{}, nil)

    snapshot = Observability.snapshot()
    assert snapshot["ssh_candidate_total"] == before["ssh_candidate_total"] + 1
    assert snapshot["ssh_proved_total"] == before["ssh_proved_total"] + 3
    assert :ets.info(Observability, :size) <= 4
    refute inspect(:ets.tab2list(Observability)) =~ "secret"

    assert Observability.snapshot()["ssh_candidate_total"] == snapshot["ssh_candidate_total"]
    assert Observability.snapshot()["ssh_proved_total"] == snapshot["ssh_proved_total"]
  end

  test "measure preserves results and exceptions without retaining exception text" do
    assert {:error, :transport_error} =
             Observability.measure(:http, fn -> {:error, :transport_error} end)

    assert_raise RuntimeError, "synthetic-private-command", fn ->
      Observability.measure(:ssh, fn -> raise "synthetic-private-command" end)
    end

    snapshot = Observability.snapshot()
    assert snapshot["http_errors"] == 1
    assert snapshot["ssh_errors"] == 1
    refute inspect(:ets.tab2list(Observability)) =~ "synthetic-private-command"
  end

  test "missing diagnostic process cannot fail a command" do
    :ok = Supervisor.terminate_child(Porsche.Supervisor, Observability)
    on_exit(fn -> Supervisor.restart_child(Porsche.Supervisor, Observability) end)
    assert :accepted = Observability.measure(:ssh, fn -> :accepted end)
    assert :ok = Observability.observe([:porsche, :ssh, :complete], %{duration_us: 7}, %{}, nil)
  end

  property "retired metric-shaped reports are redacted like any other report" do
    check all(secret <- binary(max_length: 2048)) do
      event = %{
        level: :info,
        msg:
          {:report,
           %{
             event: "metrics.summary",
             service: secret,
             token: secret,
             metrics: %{"http_count" => 3, "command" => secret}
           }},
        meta: %{token: secret, report_cb: fn _ -> secret end, porsche_private: true}
      }

      assert Porsche.Privacy.filter(event, nil) == %{
               level: :info,
               msg: {:string, "Porsche runtime_report (payload redacted)"},
               meta: %{
                 domain: [:porsche],
                 event: "porsche.runtime_report",
                 report_category: "runtime_report"
               }
             }
    end
  end

  test "actual periodic emission reaches raw handlers with numeric metrics only" do
    :ok = :logger.add_handler(:porsche_metrics_test, Handler, %{level: :all, config: self()})
    on_exit(fn -> :logger.remove_handler(:porsche_metrics_test) end)
    Observability.measure(:ssh, fn -> %{exit_status: 0} end)
    send(Observability, :report)

    assert_receive {:metric_event,
                    %{
                      meta: %{
                        event: "porsche.runtime_metrics",
                        ssh_count: count,
                        ssh_duration_us: duration
                      }
                    }}

    assert count == 1
    assert is_integer(duration) and duration >= 0
  end

  test "sanitized metrics survive the standard logger translation path" do
    output =
      ExUnit.CaptureLog.capture_log(
        [formatter: {LoggerJSON.Formatters.Basic, metadata: [:event, :http_errors]}],
        fn ->
          Observability.measure(:http, fn -> {:error, :transport_error} end)
          send(Observability, :report)
          :sys.get_state(Observability)
        end
      )

    assert output =~ "Runtime metrics observed"
    assert output =~ "http_errors"
    refute output =~ "process data redacted"
  end
end
