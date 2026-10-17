import json
import shlex

# @cc [owner:ghuntley,label:verification] brady-network-native-scope
# Use packaged Brady, actual Lilly nftables, policy routing and restricted UID/
# capability sockets. Veth peers stand in for guests; this check MUST NOT be
# reported as Firecracker, authoritative attribution or ZFS cache acceptance.
router.start()
router.wait_for_unit("multi-user.target")
router.succeed("brady-network-prepare")
identity = json.loads(router.succeed("cat /run/brady-network.json"))
ns = shlex.quote(identity["namespace"])
router.succeed(
    f"ip netns add {ns}",
    f"ip -n {ns} link set lo up",
    f"ip netns exec {ns} sysctl -w net.ipv4.ip_forward=1",
    f"ip netns exec {ns} sysctl -w net.ipv4.conf.all.rp_filter=0",
)
for name in ["guest", "guest2", "customer"]:
    tap, address, gateway, mac = [
        shlex.quote(identity[name][k]) for k in ("tap", "address", "gateway", "mac")
    ]
    router.succeed(
        f"ip netns add {name}",
        f"ip link add {tap} netns {ns} type veth peer name eth0 netns {name}",
        f"ip -n {ns} addr add {gateway}/32 dev {tap}",
        f"ip -n {ns} link set {tap} up",
        f"ip -n {ns} route add {address}/32 dev {tap}",
        f"ip -n {name} link set eth0 address {mac}",
        f"ip -n {name} addr add {address}/32 dev eth0",
        f"ip -n {name} link set eth0 up",
        f"ip -n {name} route add {gateway}/32 dev eth0",
        f"ip -n {name} route add default via {gateway}",
    )
router.succeed(
    "ip netns add origin",
    f"ip link add uplink netns {ns} type veth peer name eth0 netns origin",
    f"ip -n {ns} addr add 169.254.255.2/30 dev uplink",
    f"ip -n {ns} link set uplink up",
    f"ip -n {ns} route add default via 169.254.255.1",
    "ip -n origin addr add 169.254.255.1/30 dev eth0",
    "ip -n origin link set eth0 up",
    "ip -n origin link set lo up",
    "ip -n origin addr add 8.8.4.4/32 dev lo",
    "ip -n origin addr add 8.8.4.6/32 dev lo",
    f"ip netns exec {ns} nft -f /run/brady-network.nft",
    f"ip -n {ns} route add local 0.0.0.0/0 dev lo table 1111",
    f"ip -n {ns} rule add priority 1111 fwmark 0x42524144/0xffffffff lookup 1111",
    "systemctl start brady-origin-test brady-network-test",
)
base = "ip netns exec guest curl --noproxy '*' --silent --show-error --max-time 4"
router.wait_until_succeeds(f"ip netns exec {ns} ss -lnt | grep :15080", timeout=30)
with subtest("transparent HTTP and verified intercepted TLS work without cache storage"):
    router.wait_until_succeeds(
        base + " http://origin.brady.test/ | grep -Fx isolated-brady-origin", timeout=45
    )
    router.succeed(
        base
        + " --cacert /run/brady-fixture/ca.pem https://origin.brady.test/ | grep -Fx isolated-brady-origin"
    )
    router.fail(base + " https://origin.brady.test/")
    headers = router.succeed(base + " -D - -o /dev/null http://origin.brady.test/")
    assert "alt-svc" not in headers.lower()
    router.succeed(
        base
        + " --cacert /run/brady-fixture/ca.pem https://tunnel.brady.test/ | grep -Fx isolated-brady-origin"
    )
# @cc [owner:ghuntley,label:verification;security] brady-https-resolver-disagreement
# A guest that dials a legitimate origin address Brady's resolver does not
# return MUST still be served over intercepted HTTPS (the origin is verified by
# upstream TLS identity at the dialled IP), including a shallow smart-HTTP git
# clone. Plain HTTP to that address MUST still be refused, and an SNI the
# origin's certificate does not cover MUST fail upstream verification.
with subtest("intercepted HTTPS and git clone survive a disagreeing guest DNS view"):
    router.succeed(
        "rm -rf /run/brady-fixture/git /tmp/brady-git-work",
        "install -d -m 755 /run/brady-fixture/git",
        "git init -q -b main /tmp/brady-git-work",
        "git -C /tmp/brady-git-work -c user.name=fixture -c user.email=f@example.test "
        "commit -q --allow-empty -m 'brady clone fixture'",
        "git clone -q --bare /tmp/brady-git-work /run/brady-fixture/git/fixture.git",
        "chmod -R a+rX /run/brady-fixture/git",
    )
    fixture_head = router.succeed("git -C /tmp/brady-git-work rev-parse HEAD").strip()
    ca = "--cacert /run/brady-fixture/ca.pem"
    mismatch = "--resolve origin.brady.test:443:8.8.4.6"
    router.succeed(
        base + f" {ca} {mismatch} https://origin.brady.test/ | grep -Fx isolated-brady-origin"
    )
    # --fail: a refusal is an HTTP error response, which curl otherwise exits 0 on.
    router.fail(base + " --fail --resolve origin.brady.test:80:8.8.4.6 http://origin.brady.test/")
    router.fail(
        base + f" --fail {ca} --resolve other.brady.test:443:8.8.4.4 https://other.brady.test/"
    )
    for resolve in ("", "-c http.curloptResolve=origin.brady.test:443:8.8.4.6 "):
        router.succeed(
            "rm -rf /tmp/brady-clone && ip netns exec guest env "
            "GIT_SSL_CAINFO=/run/brady-fixture/ca.pem GIT_TERMINAL_PROMPT=0 "
            f"git {resolve}clone -q --depth 1 https://origin.brady.test/fixture.git /tmp/brady-clone"
        )
        assert router.succeed("git -C /tmp/brady-clone rev-parse HEAD").strip() == fixture_head
        assert (
            router.succeed("git -C /tmp/brady-clone rev-parse --is-shallow-repository").strip()
            == "true"
        )

with subtest("Customer and protected destinations remain denied"):
    router.fail(base.replace("exec guest", "exec customer") + " http://origin.brady.test/")
    router.fail(base + " http://8.8.4.5/", base + " http://169.254.255.1/")
with subtest("proxy outage cannot fall back to direct web forwarding"):
    router.succeed("systemctl stop brady-network-test")
    router.fail(
        base + " http://origin.brady.test/",
        base + " --cacert /run/brady-fixture/ca.pem https://origin.brady.test/",
    )
    router.succeed("systemctl start brady-network-test")
    router.wait_until_succeeds(
        base + " http://origin.brady.test/ | grep -Fx isolated-brady-origin", timeout=45
    )
with subtest("HTTP3-capable client falls back after the kernel rejects QUIC"):
    router.succeed("curl --version | grep HTTP3")

    def quic_rejections() -> int:
        rules = json.loads(
            router.succeed(f"ip netns exec {ns} nft -j list chain inet lilly_filter forward")
        )
        return sum(
            expression["counter"]["packets"]
            for row in rules["nftables"]
            if "rule" in row
            if any("reject" in item for item in row["rule"]["expr"])
            for expression in row["rule"]["expr"]
            if "counter" in expression
        )

    rejected_before = quic_rejections()
    router.succeed(
        base
        + " --http3 --cacert /run/brady-fixture/ca.pem https://origin.brady.test/ | grep -Fx isolated-brady-origin"
    )
    assert quic_rejections() > rejected_before
with subtest("request secrets and payloads stay out of structured journal"):
    router.succeed(
        base
        + " -H 'Authorization: Bearer brady-synthetic-secret' 'http://origin.brady.test/?signed=brady-synthetic-signature' >/dev/null"
    )
    brady_journal = router.succeed("journalctl -u brady-network-test -o cat --no-pager")
    for forbidden in [
        "brady-synthetic-secret",
        "brady-synthetic-signature",
        "isolated-brady-origin",
        "origin.brady.test",
    ]:
        assert forbidden not in brady_journal
