first.start(allow_reboot=True)
second.start()
third.start()
sink.start()
sink.wait_for_unit("fixture.service")
for machine in [first, second, third]:
    machine.wait_for_unit("overalls-logging.service")
    machine.succeed("logger overalls-export-fixture")
for name in ["first", "second", "third"]:
    sink.wait_until_succeeds(
        f"grep 'overalls-export-fixture' /tmp/received.jsonl | grep '\"hostname\":\"{name}\"'"
    )
# Stopping one exporter leaves every other producer/exporter independent.
first.succeed("systemctl stop overalls-logging.service; logger overalls-offline-fixture")
first.wait_for_unit("overalls-logging-health.service")
first.succeed(
    "curl -fsS http://127.0.0.1:9467/metrics | grep '^overalls_logging_filesystem_valid 1$'"
)
first.succeed(
    "curl -fsS http://127.0.0.1:9467/metrics | grep '^overalls_logging_collector_metrics_valid 0$'"
)
first.fail("curl -fsS http://127.0.0.1:9467/metrics | grep '^overalls_logging_output_errors_total'")
second.succeed("logger overalls-independent-fixture")
sink.wait_until_succeeds("grep overalls-independent-fixture /tmp/received.jsonl")
first.succeed("systemctl start overalls-logging.service")
sink.wait_until_succeeds("grep overalls-offline-fixture /tmp/received.jsonl")
# Destination outage must not stop local collection. Restart it and drain the queue.
sink.succeed("systemctl stop fixture.service")
third.succeed("logger overalls-destination-outage-fixture")
third.sleep(3)
old_pid = third.succeed("systemctl show -p MainPID --value overalls-logging.service").strip()
third.succeed("systemctl kill --signal=SIGKILL --kill-whom=main overalls-logging.service")
third.wait_until_succeeds(
    f'test "$(systemctl show -p MainPID --value overalls-logging.service)" != "{old_pid}" && systemctl is-active overalls-logging.service'
)
third.succeed("systemctl is-active overalls-logging.service")
sink.succeed("systemctl start fixture.service")
sink.wait_until_succeeds("grep overalls-destination-outage-fixture /tmp/received.jsonl")
first.succeed("systemctl stop overalls-logging.service; logger overalls-before-reboot-fixture")
first.succeed(
    "journalctl --sync; journalctl --grep=overalls-before-reboot-fixture --no-pager | grep overalls-before-reboot-fixture"
)
first.reboot()
first.succeed(
    "journalctl --grep=overalls-before-reboot-fixture --no-pager | grep overalls-before-reboot-fixture"
)
first.wait_for_unit("overalls-logging.service")
sink.wait_until_succeeds("grep overalls-before-reboot-fixture /tmp/received.jsonl")

first.wait_for_unit("overalls-audit-watches.service")
# Invoke an executable: shell builtins do not produce an exec record.
first.succeed("/run/current-system/sw/bin/true overalls-audit-argument-fixture")
sink.wait_until_succeeds(
    'grep overalls-audit-argument-fixture /tmp/received.jsonl | grep \'"source":"audit"\''
)
first.succeed(
    "python /etc/logging-runtime-test.py /etc/logging-runtime.py /etc/native-collector.py"
)

for name in ["first", "second", "third"]:
    sink.wait_until_succeeds(
        f"grep 'overalls-export-fixture' /tmp/cloudwatch.jsonl | grep '\"hostname\":\"{name}\"'"
    )
sink.wait_until_succeeds("grep -a overalls-export-fixture /tmp/otlp.bin")
sink.fail("grep overalls-audit-argument-fixture /tmp/cloudwatch.jsonl")
sink.wait_until_succeeds("grep overalls-destination-outage-fixture /tmp/cloudwatch.jsonl")
sink.wait_until_succeeds("grep -a overalls-destination-outage-fixture /tmp/otlp.bin")
