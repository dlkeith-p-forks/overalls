# Nix layout

The root flake is the public interface. Its package, module, machine and check
names are explicit; files underneath this directory are internal implementation
paths. See the [deployment guide](../docs/nixos.md) for service options and rollout.

| Directory | Responsibility |
| --- | --- |
| `packages/` | Source-built application releases, the shared toolchain, guest image, host helpers and public operator recipient. `default.nix` assembles the package set. |
| `modules/` | Reusable NixOS service and storage modules. ACME and secret-delivery scripts live with their owning modules. |
| `hosts/` | Inventory-derived Hetzner/EC2 profiles; the host tool separates installation and enrollment. |
| `tests/` | The explicit check catalog, evaluation/release checks, machine suites and shared test support. |

Application packages use the development package input; host modules and machine
tests use the separately pinned stable NixOS input. Keep this distinction explicit
when changing wiring. Source packages retain their existing allowlist, so moving
tests or documentation does not add them to application release inputs.

The standalone `nixosModules.sysctl` profile (also available through the default
module) requires explicit `overalls.sysctl.enable = true`. It selects BBR and fq
while inheriting resource limits; see the [host TCP guide](../docs/nixos.md#opt-in-host-tcp-profile).

Fleet host profiles enable `programs.nix-ld` so unpackaged dynamically linked
Linux executables can use the FHS interpreter path. Guest images do not inherit
that setting; see [non-Nix executables](../docs/nixos.md#non-nix-executables).

`users.nix` is the reviewed public registry for named host accounts, groups,
administrators and recovery membership. `allowed-hosts.nix` is the reviewed
public registry of named IPv4 sources allowed to reach every fleet host over
TCP and UDP; each grant includes a required operator-facing comment.
`secrets.nix` derives ciphertext documents and authenticated public host keys
from `fleet/hosts/NAME/host.json`. The access module and recipient/tool packages
consume that policy; see [fleet users](../docs/fleet-users.md). Private identities
and plaintext deployment credentials are generated or delivered at runtime.

Use the [test catalog](tests/README.md) to find a suite or shared fixture. Read
ancestor `CONTRACTS` and local notes before changing any code. Architecture and
implementation evidence remain in the [ADRs](../docs/architecture/decisions/README.md).

Host observability modules and examples are documented in
[per-host observability](../docs/observability.md). Exporters run on each host;
CloudWatch management is separate and never receives fleet logs.
