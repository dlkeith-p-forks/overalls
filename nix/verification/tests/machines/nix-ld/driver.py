"""Verify unpackaged dynamically linked ELFs against nix-ld and stub-ld."""

from typing import Final

start_all()
for machine in [enabled, disabled]:
    machine.wait_for_unit("multi-user.target")

LOGIN: Final[str] = "bash -lc unpatched-dynamic-hello"

with subtest("enabled host runs an unpackaged dynamically linked ELF"):
    output = enabled.succeed(LOGIN)
    assert "overalls-dynamic-hello" in output, output
    ldso = enabled.succeed("readlink -f /lib64/ld-linux-x86-64.so.2")
    assert "nix-ld" in ldso, ldso
    env = enabled.succeed("bash -lc 'printf %s \"$NIX_LD\"'")
    assert env.strip().endswith("/share/nix-ld/lib/ld.so"), env

with subtest("disabled host keeps the stub loader and refuses the ELF"):
    stub = disabled.succeed("readlink -f /lib64/ld-linux-x86-64.so.2")
    assert "stub-ld" in stub, stub
    disabled.fail(LOGIN)
