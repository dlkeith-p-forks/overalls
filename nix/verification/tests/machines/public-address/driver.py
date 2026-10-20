import json

ipv4 = "192.168.1.2"
ipv6 = "2001:db8:5::2"
drop_in = "/run/systemd/network/40-eth1.network.d/50-public-address.conf"


def seal(public_ipv4: str, public_ipv6: str) -> None:
    payload = json.dumps(
        {
            "overalls-public-address": {
                "production": {"PUBLIC_IPV4": public_ipv4, "PUBLIC_IPV6": public_ipv6}
            }
        }
    )
    host.succeed(
        "install -d -m 0700 /run/public-address-sealed && umask 077 && "
        f"printf '%s' '{payload}' | sops --encrypt --age \"$(ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub)\" "
        "--input-type json --output-type json /dev/stdin > /run/public-address-sealed/address.new && "
        "mv /run/public-address-sealed/address.new /run/public-address-sealed/address.enc.json"
    )


def apply() -> None:
    # Restarting the bundle propagates through Requires= to the address unit
    # and the listener, as a deployed document change does.
    host.succeed("systemctl restart overalls-secrets-public-address.service")
    host.succeed("systemctl start overalls-public-address.service overalls-public-web.service")


def reachable(port: int) -> bool:
    status, _ = client.execute(
        f"curl -sf --max-time 3 http://{ipv4}:{port}/ | grep -Fx public-address-fixture"
    )
    return status == 0


start_all()
host.wait_for_unit("fixture-web-80.service")
host.wait_for_unit("fixture-web-8080.service")
host.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
client.wait_for_unit("multi-user.target")

with subtest("no listener before the document decrypts"):
    host.fail("systemctl is-active overalls-public-address.service")
    host.succeed("iptables -w -S nixos-fw | grep -F -- '-j overalls-public-web'")
    assert host.succeed("iptables -w -S overalls-public-web").strip() == "-N overalls-public-web"
    host.fail(f"test -e {drop_in}")
    assert not reachable(80)

with subtest("decrypted addresses open only the declared listener"):
    seal(ipv4, ipv6 + "/64")
    apply()
    rules = host.succeed("iptables -w -S overalls-public-web")
    assert f"-d {ipv4}/32 -p tcp -m tcp --dport 80" in rules, rules
    assert reachable(80)
    assert not reachable(8080)
    host.succeed(f"grep -Fx 'Address={ipv6}/64' {drop_in}")
    host.wait_until_succeeds(f"ip -6 addr show dev eth1 | grep -F {ipv6}/64", timeout=30)
    client.wait_until_succeeds(f"ping -6 -c1 -W2 {ipv6}", timeout=30)
    host.fail("grep -rF 'PUBLIC_IPV4' /etc/systemd/network")

with subtest("a firewall reload keeps the validated rules"):
    host.succeed("systemctl reload firewall.service")
    assert reachable(80)
    host.succeed("systemctl restart firewall.service")
    host.wait_for_unit("overalls-public-web.service")
    assert reachable(80)

with subtest("rotation replaces the address"):
    seal("192.168.1.99", "2001:db8:5::99/64")
    apply()
    rules = host.succeed("iptables -w -S overalls-public-web")
    assert ipv4 not in rules and "192.168.1.99/32" in rules, rules
    assert not reachable(80)
    host.wait_until_succeeds("ip -6 addr show dev eth1 | grep -F 2001:db8:5::99/64", timeout=30)
    host.wait_until_succeeds(f"! ip -6 addr show dev eth1 | grep -F '{ipv6}/64'", timeout=30)

with subtest("a malformed document closes the listener"):
    seal(ipv4, ipv6 + "/64")
    apply()
    assert reachable(80)
    seal("0.0.0.0", "not-an-address")
    host.succeed("systemctl restart overalls-secrets-public-address.service")
    host.fail("systemctl is-active overalls-public-address.service")
    host.fail("systemctl is-active overalls-public-web.service")
    host.fail("systemctl start overalls-public-address.service")
    assert host.succeed("iptables -w -S overalls-public-web").strip() == "-N overalls-public-web"
    host.fail(f"test -e {drop_in}")
    assert not reachable(80)
