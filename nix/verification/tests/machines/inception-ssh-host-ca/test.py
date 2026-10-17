"""Independent nested SSH CA custody and stable, namespace-bound runtime policy."""

import json


def policy_value(data: object) -> tuple[str, str, str, int]:
    match data:
        case {
            "version": 1,
            "ca": str(ca),
            "management_host": str(host),
            "zone": str(zone),
            "retirement": int(retirement),
        }:
            return ca, host, zone, retirement
        case _:
            raise AssertionError("invalid SSH trust policy")


start_all()
keys: list[str] = []
for machine in [first, second]:
    machine.wait_for_unit("marshall-inception.service")
    policy = policy_value(json.loads(machine.succeed("cat /run/ssh-ca-probe/policy.json")))
    ca, host, zone, retirement = policy
    key = machine.succeed("cat /run/ssh-ca-probe/public-key").strip()
    assert ca == key
    assert host == "control.example.test"
    assert zone == "apps.example.test"
    now = int(machine.succeed("date +%s"))
    assert 19 * 365 * 86400 < retirement - now < 21 * 365 * 86400
    machine.fail("runuser -u nobody -- cat /var/lib/inception/ssh-ca/key")
    machine.succeed("systemctl restart inception-ssh-trust.service marshall-inception.service")
    assert machine.succeed("cat /run/ssh-ca-probe/public-key").strip() == key
    assert policy_value(json.loads(machine.succeed("cat /run/ssh-ca-probe/policy.json"))) == policy
    keys.append(key)
assert keys[0] != keys[1]
first.succeed("rm /var/lib/inception/ssh-ca/key")
first.fail("systemctl restart inception-ssh-trust.service")
first.succeed("test ! -e /var/lib/inception/ssh-ca/key")
