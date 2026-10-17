"""Bounded guest readiness diagnostics for composed fleet drivers."""

from collections.abc import Sequence
from typing import Protocol


class DiagnosingMachine(Protocol):
    """Provisioner methods supplied by the composed NixOS test driver machine."""

    name: str

    def execute(
        self,
        command: str,
        check_return: bool = True,
        check_output: bool = True,
        timeout: int | None = 900,
    ) -> tuple[int, str]: ...


def dump_guest_diagnostics(machines: Sequence[DiagnosingMachine]) -> None:
    """@cc [owner:ghuntley,label:verification] fleet-guest-diagnostics-dump
    Print only the guest's fleet-readiness-diagnostics blocks and the last five
    serial console lines from each provisioner's boot logs. Callers MUST run it
    before Lilly removes a failed VM's directory; the guest console never
    carries terminal sessions.
    """
    script = (
        'for f in /var/lib/lilly/vms/*/boot.log; do [ -f "$f" ] || continue; '
        'echo "== $f"; tail -c 65536 "$f" | '
        "sed -n '/=== fleet-readiness-diagnostics/,/=== end fleet-readiness-diagnostics/p'; "
        'echo "-- console tail"; tail -n 5 "$f"; done'
    )
    for machine in machines:
        print(machine.name, machine.execute(script, check_return=False)[1])
