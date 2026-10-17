import json
import shlex

# @cc [owner:ghuntley,label:verification] private-network-kernel-scope
# Exercise packaged Audi TLS/DNS and Lilly nftables against actual Linux network
# namespaces. This is kernel integration, not Firecracker or provider acceptance.
router.start()
router.wait_for_unit("multi-user.target")
router.succeed("private-network-prepare")
identity = json.loads(router.succeed("cat /run/private-network.json"))
namespace = shlex.quote(identity["namespace"])
router.succeed(f"ip netns add {namespace}")
router.succeed(f"ip -n {namespace} link set lo up")
router.succeed(f"ip -n {namespace} addr add 169.254.254.1/32 dev lo")
for name in ["guest", "customer"]:
    guest = identity[name]
    tap, address, gateway, mac = [
        shlex.quote(guest[k]) for k in ("tap", "address", "gateway", "mac")
    ]
    router.succeed(f"ip netns add {name}")
    router.succeed(f"ip link add {tap} netns {namespace} type veth peer name eth0 netns {name}")
    router.succeed(f"ip -n {namespace} addr add {gateway}/32 dev {tap}")
    router.succeed(f"ip -n {namespace} link set {tap} up")
    router.succeed(f"ip -n {namespace} route add {address}/32 dev {tap}")
    router.succeed(f"ip -n {name} link set eth0 address {mac}")
    router.succeed(f"ip -n {name} addr add {address}/32 dev eth0")
    router.succeed(f"ip -n {name} link set eth0 up")
    router.succeed(f"ip -n {name} route add {gateway}/32 dev eth0")
    router.succeed(f"ip -n {name} route add default via {gateway}")
router.succeed(f"ip netns exec {namespace} nft -f /run/private-network.nft")
router.succeed("systemctl start private-audi-test")
for transport in ["", "+tcp"]:
    router.wait_until_succeeds(
        f"ip netns exec guest dig @169.254.254.1 llm.internal A +short +time=1 +tries=1 {transport} | grep -Fx 169.254.254.1",
        timeout=30,
    )
    router.wait_until_succeeds(
        f"ip netns exec guest dig @169.254.254.1 exedev.integration.internal A +short +time=1 +tries=1 {transport} | grep -Fx 169.254.254.1"
    )
    assert "NXDOMAIN" in router.succeed(
        f"ip netns exec guest dig @169.254.254.1 unknown.internal A +time=1 +tries=1 {transport}"
    )
    assert "NXDOMAIN" in router.succeed(
        f"ip netns exec guest dig @169.254.254.1 a.b.integration.internal A +time=1 +tries=1 {transport}"
    )
    assert "REFUSED" in router.succeed(
        f"ip netns exec guest dig @169.254.254.1 example.com A +time=1 +tries=1 {transport}"
    )
curl = "ip netns exec guest curl --noproxy '*' --silent --show-error --max-time 3 --resolve llm.internal:443:169.254.254.1"
integration_curl = "ip netns exec guest curl --noproxy '*' --silent --show-error --max-time 3 --resolve exedev.integration.internal:443:169.254.254.1"
router.wait_until_succeeds(
    curl
    + " --cacert /run/private-audi/roots.pem -o /dev/null -w '%{http_code}' https://llm.internal/v1/models | grep -Fx 403"
)
router.wait_until_succeeds(
    integration_curl
    + " --cacert /run/private-audi/roots.pem -o /dev/null -w '%{http_code}' https://exedev.integration.internal/ | grep -Fx 403"
)
router.fail(curl + " https://llm.internal/v1/models")
router.succeed(
    curl
    + " --cacert /run/private-audi/roots.pem -H 'x-overalls-binding: forged' -H 'Authorization: Bearer synthetic' -o /dev/null -w '%{http_code}' https://llm.internal/v1/models | grep -Fx 403"
)
router.fail("curl --noproxy '*' --max-time 1 --connect-timeout 1 https://169.254.254.1")
router.fail("su -s /bin/sh nobody -c 'cat /run/private-audi/key.pem'")
router.succeed("systemctl restart private-audi-test")
router.wait_until_succeeds(
    curl
    + " --cacert /run/private-audi/roots.pem -o /dev/null -w '%{http_code}' https://llm.internal/v1/models | grep -Fx 403"
)

# Customer reaches the fixed authority; Audi allows only ssh.integration.internal through.
for transport in ["", "+tcp"]:
    router.succeed(
        f"ip netns exec customer dig @169.254.254.1 ssh.integration.internal A +short +time=1 +tries=1 {transport} | grep -Fx 169.254.254.1"
    )
customer_curl = "ip netns exec customer curl --noproxy '*' --silent --show-error --max-time 3 --cacert /run/private-audi/roots.pem"
for name, path in [("llm.internal", "/v1/models"), ("ssh.integration.internal", "/ssh/v1/roster")]:
    router.succeed(
        customer_curl
        + f" --resolve {name}:443:169.254.254.1 -o /dev/null -w '%{{http_code}}' https://{name}{path} | grep -Fx 403"
    )
