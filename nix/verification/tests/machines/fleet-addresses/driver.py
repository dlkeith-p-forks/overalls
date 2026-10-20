import json

hosts = {"legacy": legacy, "nft": nft}
address = {"legacy": "192.168.1.2", "nft": "192.168.1.3"}
uplink = "10.20.0.2"
drop_in = "/run/systemd/network/40-eth2.network.d/50-fleet-addresses.conf"
recovery = "/var/lib/overalls-host/uplink.conf"


def seal(name: str, values: dict[str, str]) -> None:
    machine = hosts[name]
    payload = json.dumps({"overalls-fleet-addresses": {"production": values}})
    machine.succeed(
        "install -d -m 0700 /run/fleet-sealed && umask 077 && "
        f"printf '%s' '{payload}' | sops --encrypt --age "
        '"$(ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub)" '
        "--input-type json --output-type json /dev/stdin > /run/fleet-sealed/new && "
        "mv /run/fleet-sealed/new /run/fleet-sealed/addresses.enc.json"
    )


def values(name: str, self_address: str, grant: str, gateway: str = "10.20.0.1") -> dict[str, str]:
    result = {"SELF_IPV4": self_address, "GRANT_IPV4": grant}
    if name == "nft":
        result |= {"UPLINK_IPV4": uplink, "UPLINK_PREFIX": "24", "UPLINK_GATEWAY_IPV4": gateway}
    return result


def apply(name: str) -> None:
    # A document change restarts the bundle; Requires= carries it to the
    # validator and PartOf= to the runtime firewall, as on a deployed host.
    machine = hosts[name]
    machine.succeed("systemctl restart overalls-secrets-fleet-addresses.service")
    machine.succeed(
        "systemctl start overalls-fleet-addresses.service overalls-runtime-firewall.service"
    )
    if name == "nft":
        machine.succeed("systemctl restart overalls-fleet-uplink.service")


def reachable(name: str, port: int) -> bool:
    status, _ = client.execute(
        f"curl -sf --max-time 3 http://{address[name]}:{port}/ | grep -Fx fleet-address-fixture"
    )
    return status == 0


def chain(name: str) -> str:
    if name == "nft":
        return nft.succeed("nft list chain inet nixos-fw overalls-runtime")
    return legacy.succeed("iptables -w -S overalls-runtime")


def empty(name: str) -> bool:
    text = chain(name)
    return "accept" not in text.lower()


start_all()
for machine in hosts.values():
    machine.wait_for_unit("fixture-web-80.service")
    machine.wait_for_unit("fixture-web-8080.service")
    machine.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
client.wait_for_unit("multi-user.target")

with subtest("nothing is admitted or addressed before the document decrypts"):
    for name, machine in hosts.items():
        machine.fail("systemctl is-active overalls-fleet-addresses.service")
        assert empty(name), chain(name)
        assert not reachable(name, 80)
    nft.fail("systemctl is-active overalls-fleet-uplink.service")
    nft.fail(f"test -e {drop_in}")
    nft.fail(f"ip -4 addr show dev eth2 | grep -F {uplink}")

with subtest("decrypted addresses open only the declared rules on both backends"):
    for name in hosts:
        seal(name, values(name, address[name], "192.0.2.99"))
        apply(name)
        assert reachable(name, 80), chain(name)
        assert not reachable(name, 8080), chain(name)
    assert "ip daddr 192.168.1.3 tcp dport 80 accept" in chain("nft"), chain("nft")
    assert "ip saddr 192.0.2.99 meta l4proto { tcp, udp } accept" in chain("nft"), chain("nft")
    assert "-d 192.168.1.2/32 -p tcp -m tcp --dport 80" in chain("legacy"), chain("legacy")
    assert "-s 192.0.2.99/32 -p udp" in chain("legacy"), chain("legacy")

with subtest("a reviewed source grant follows its runtime address"):
    for name in hosts:
        seal(name, values(name, address[name], "192.168.1.1"))
        apply(name)
        assert reachable(name, 8080), chain(name)

with subtest("firewall reloads and restarts refill the runtime chain"):
    nft.succeed("systemctl reload nftables.service")
    nft.wait_until_succeeds(
        "nft list chain inet nixos-fw overalls-runtime | grep -F 'dport 80 accept'", timeout=30
    )
    assert reachable("nft", 80)
    nft.succeed("systemctl restart nftables.service")
    nft.wait_for_unit("overalls-runtime-firewall.service")
    assert reachable("nft", 80)
    legacy.succeed("systemctl reload firewall.service")
    assert reachable("legacy", 80)
    legacy.succeed("systemctl restart firewall.service")
    legacy.wait_for_unit("overalls-runtime-firewall.service")
    assert reachable("legacy", 80)

with subtest("the uplink is a runtime drop-in with a recovery copy"):
    nft.succeed(f"grep -Fx 'Address={uplink}/24' {drop_in}")
    nft.succeed(f"grep -Fx 'Gateway=10.20.0.1' {drop_in}")
    nft.wait_until_succeeds(f"ip -4 addr show dev eth2 | grep -F {uplink}/24", timeout=30)
    client.wait_until_succeeds(f"ping -c1 -W2 {uplink}", timeout=30)
    assert nft.succeed(f"stat -c %a:%U {recovery}").strip() == "600:root"
    nft.succeed(f"cmp {recovery} {drop_in}")
    nft.fail("grep -rF 10.20.0.2 /etc/systemd/network")

with subtest("rotation replaces the admitted address"):
    for name in hosts:
        seal(name, values(name, "198.51.100.7", "192.0.2.99"))
        apply(name)
        assert not reachable(name, 80), chain(name)
        assert "198.51.100.7" in chain(name), chain(name)

with subtest("a malformed document closes every rule but keeps the uplink"):
    for name, machine in hosts.items():
        seal(name, values(name, address[name], "192.168.1.1"))
        apply(name)
        assert reachable(name, 80)
        seal(name, values(name, "0.0.0.0", "not-an-address", gateway="10.99.0.1"))
        machine.succeed("systemctl restart overalls-secrets-fleet-addresses.service")
        machine.fail("systemctl is-active overalls-fleet-addresses.service")
        machine.fail("systemctl is-active overalls-runtime-firewall.service")
        assert empty(name), chain(name)
        assert not reachable(name, 80)
    nft.succeed("systemctl restart overalls-fleet-uplink.service")
    nft.succeed(
        "journalctl -u overalls-fleet-uplink.service | grep -F fleet_uplink.recovery_copy_used"
    )
    nft.succeed(f"grep -Fx 'Address={uplink}/24' {drop_in}")
    client.succeed(f"ping -c1 -W2 {uplink}")
