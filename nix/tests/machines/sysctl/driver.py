"""Verify the opt-in profile in real kernels, including sockets and reboot."""

import json

start_all()
for machine in [enabled, disabled]:
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("systemd-sysctl.service")
    machine.wait_for_unit("tcp-probe.service")
    machine.wait_for_open_port(8123)

inherited_keys = [
    "fs.file-max",
    "fs.inotify.max_user_instances",
    "fs.inotify.max_user_watches",
    "kernel.pid_max",
    "net.core.rmem_max",
    "net.core.wmem_max",
    "net.ipv4.ip_forward",
]
baseline = {key: disabled.succeed(f"sysctl -n {key}").strip() for key in inherited_keys}
baseline_algorithm = disabled.succeed("sysctl -n net.ipv4.tcp_congestion_control").strip()


def check_profile() -> None:
    """Check applied policy without configuring sysctls or replacing queues in the test."""
    assert enabled.succeed("sysctl -n net.ipv4.tcp_congestion_control").strip() == "bbr"
    assert enabled.succeed("sysctl -n net.core.default_qdisc").strip() == "fq"
    assert "bbr" in enabled.succeed("sysctl -n net.ipv4.tcp_available_congestion_control").split()
    enabled.succeed("test -d /sys/module/tcp_bbr && test -d /sys/module/sch_fq")
    queues = json.loads(enabled.succeed("tc -j qdisc show dev eth1"))
    assert any(queue["kind"] == "fq" for queue in queues), queues
    for key, expected in baseline.items():
        assert enabled.succeed(f"sysctl -n {key}").strip() == expected, key
    enabled.succeed(f"{probe} client disabled bbr {baseline_algorithm}")
    disabled.succeed(f"{probe} client enabled {baseline_algorithm} bbr")


with subtest("explicit profile applies with inherited resource and forwarding policy"):
    check_profile()
    disabled.fail("grep -E '^(tcp_bbr|sch_fq)$' /etc/modules-load.d/nixos.conf")
    disabled.fail(
        "grep -E '^(net.ipv4.tcp_congestion_control|net.core.default_qdisc)=' /etc/sysctl.d/60-nixos.conf"
    )

with subtest("reboot retains effective policy and connected-socket behavior"):
    # The driver's default QEMU exits on reboot; retain its disk and start again.
    enabled.reboot()
    enabled.wait_for_shutdown()
    enabled.start()
    enabled.wait_for_unit("multi-user.target")
    enabled.wait_for_unit("tcp-probe.service")
    enabled.wait_for_open_port(8123)
    check_profile()
