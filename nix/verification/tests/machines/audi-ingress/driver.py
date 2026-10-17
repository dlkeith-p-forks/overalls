import json
import shlex

# @cc [owner:ghuntley,label:verification] ingress-kernel-test-scope
# This check MUST exercise the packaged connector and actual nftables/namespace
# behavior. Veth echo fixtures MUST NOT be described as Firecracker acceptance.
connector.start()
connector.wait_for_unit("multi-user.target")
connector.succeed("ingress-check prepare")
identity = json.loads(connector.succeed("cat /run/ingress.json"))
namespace = shlex.quote(identity["namespace"])
connector.succeed(f"ip netns add {namespace}")
connector.succeed(f"ip netns exec {namespace} sysctl -qw net.ipv4.ip_forward=1")
for number, guest in enumerate(identity["guests"], 1):
    name = f"guest{number}"
    tap, address, gateway, mac = [
        shlex.quote(guest[k]) for k in ("tap", "address", "gateway", "mac")
    ]
    connector.succeed(f"ip netns add {name}")
    connector.succeed(f"ip link add {tap} netns {namespace} type veth peer name eth0 netns {name}")
    connector.succeed(f"ip -n {namespace} addr add {gateway}/32 dev {tap}")
    connector.succeed(f"ip -n {namespace} link set {tap} up")
    connector.succeed(f"ip -n {namespace} route add {address}/32 dev {tap}")
    connector.succeed(f"ip -n {name} link set eth0 address {mac}")
    connector.succeed(f"ip -n {name} addr add {address}/32 dev eth0")
    connector.succeed(f"ip -n {name} link set eth0 up")
    connector.succeed(f"ip -n {name} route add {gateway}/32 dev eth0")
    connector.succeed(f"ip -n {name} route add default via {gateway}")
    connector.succeed(
        f"systemd-run --unit={name} ip netns exec {name} /run/current-system/sw/bin/python3 /etc/ingress-echo.py {name} 22 23 80 443 3000 4444 9999"
    )
    connector.wait_until_succeeds(f"test -f /run/{name}.ready", timeout=30)
connector.succeed(
    f"systemd-run --unit=namespace-host ip netns exec {namespace} /run/current-system/sw/bin/python3 /etc/ingress-echo.py host 2222"
)
connector.wait_until_succeeds("test -f /run/host.ready", timeout=30)
connector.succeed(f"ip netns exec {namespace} nft -f /run/ingress.nft")

with subtest("only explicitly enabled, service-marked local connections succeed"):
    connector.succeed("ingress-check marked")
    connector.succeed("ingress-check web")
    connector.succeed("ingress-check editor-mark")
    connector.succeed("ingress-check customer-web")
    connector.succeed("ingress-check disabled")
    connector.succeed("ingress-check unmarked")
    connector.succeed("ingress-check wrong-port")
    connector.succeed(
        f"ip netns exec {namespace} setpriv --reuid=65534 --regid=65534 --clear-groups --bounding-set=-all /run/current-system/sw/bin/python3 /etc/ingress-denied.py --mark"
    )

with subtest("guests cannot initiate host or lateral TCP connections"):
    connector.succeed("ip netns exec guest1 python3 /etc/ingress-denied.py 10.10.0.1 2222")
    connector.succeed("ip netns exec guest1 python3 /etc/ingress-denied.py 10.20.0.3 22")
    connector.succeed("ip netns exec guest2 python3 /etc/ingress-denied.py 10.10.0.2 22")

with subtest("new forwarded host traffic cannot use the local exception"):
    connector.succeed(f"ip link add outer type veth peer name uplink netns {namespace}")
    connector.succeed("ip addr add 169.254.255.1/30 dev outer")
    connector.succeed("ip link set outer up")
    connector.succeed(f"ip -n {namespace} addr add 169.254.255.2/30 dev uplink")
    connector.succeed(f"ip -n {namespace} link set uplink up")
    connector.succeed("ip route add 10.10.0.0/16 via 169.254.255.2")
    connector.succeed("python3 /etc/ingress-denied.py 10.10.0.2 22")
    connector.succeed("ingress-check marked")
    connector.succeed("ingress-check web")
    connector.succeed("ingress-check customer-web")

with subtest("Customer drops TCP UDP DNS and ICMP while unrestricted egress works"):
    connector.succeed("ip addr add 11.0.0.1/32 dev outer")
    connector.succeed(f"ip -n {namespace} route add default via 169.254.255.1")
    connector.succeed("systemd-run --unit=egress-tcp python3 /etc/ingress-echo.py egress 8080")
    connector.wait_until_succeeds("test -f /run/egress.ready", timeout=30)
    connector.succeed("systemd-run --unit=egress-udp python3 /etc/ingress-egress.py udp-server")
    connector.wait_until_succeeds("ip netns exec guest2 python3 /etc/ingress-egress.py allow")
    connector.succeed("ip netns exec guest2 ping -c 1 -W 1 11.0.0.1")
    connector.succeed("ip netns exec guest1 python3 /etc/ingress-egress.py deny")
    connector.fail("ip netns exec guest1 ping -c 1 -W 1 11.0.0.1")

with subtest("policy replacement blocks an established Customer outbound flow"):
    # Deliberately restore the old permissive egress policy in this isolated
    # fixture, establish a real connection, then apply the production policy.
    rules = connector.succeed("cat /run/ingress.nft")
    old = rules.replace('iifname "lv*" ip saddr 10.10.0.0/16 counter drop\n', "")
    old = old.replace('oifname "lv*" ip daddr 10.10.0.0/16 counter drop\n', "")
    old = old.replace("ip saddr { 10.20.0.0/16,", "ip saddr { 10.10.0.0/16, 10.20.0.0/16,")
    connector.succeed("printf %s " + shlex.quote(old) + " > /run/legacy-egress.nft")
    connector.succeed(f"ip netns exec {namespace} nft -f /run/legacy-egress.nft")
    connector.succeed("python3 /etc/ingress-egress.py established")
    connector.succeed("ingress-check marked")
    connector.succeed("ingress-check customer-web")
    connector.succeed("ip netns exec guest1 python3 /etc/ingress-egress.py deny")

with subtest("policy replacement also blocks an established marked Customer web stream"):
    old_web = rules.replace('iifname "lv*" ip saddr 10.10.0.0/16 counter drop;', "")
    old_web = old_web.replace("ip daddr { 10.20.0.0/16,", "ip daddr { 10.10.0.0/16, 10.20.0.0/16,")
    connector.succeed("printf %s " + shlex.quote(old_web) + " > /run/legacy-web.nft")
    connector.succeed(f"ip netns exec {namespace} nft -f /run/legacy-web.nft")
    connector.succeed("python3 /etc/ingress-egress.py established-web")
    connector.succeed("ingress-check marked")
