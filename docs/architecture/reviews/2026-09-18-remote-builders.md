# Reciprocal Nix builders review

Date: 2026-09-18

## Scope and architecture impact

ADR-0067 supersedes ADR-0044 solely to add an opt-in restricted machine-account
exception and reciprocal Nix build trust. All inherited human access, secret
recovery/custody, provisioning and updater policies remain. No application
placement, protocol, guest resource budget or host identity changes.

## Identity and credentials

Strict SSH verification succeeded against inventory for Dungarees at
DUNGAREES_PRIMARY_IPV4:22 and Overalls at OVERALLS_PRIMARY_IPV4:2222, with named administrative
sudo access. Both report 32 logical CPUs. Overalls' returned host public key
matches inventory. The different local bare-overalls known-host entry was not
used or replaced. No unauthenticated observation was promoted into inventory.

Distinct client keys were generated outside Git/store, encrypted through the
inventory CLI, and decrypted with the retained recovery identity to verify each
public-key match. All 22 inventory documents passed recipient checks. Temporary
plaintext was removed. No host key or separate cache-signing private key was
created or changed.

## Review findings

The Nix account is privileged build/store authority despite its forced command;
mutual trust is intentional. Signature bypass is scoped to authenticated SSH
URLs. Local slots remain available. Ordinary SSH shell, PTY, forwarding and RC
paths are disabled. The account cannot read the root-owned outbound key.
Nix's trusted buildDerivation remote path bypasses the receiver's build hook;
the machine check requires successful work with both peers configured.

The updater discovers Nix through its PartOf secret relationship. Preparation is
a Wants dependency so a failed credential cannot disable local Nix. Existing
Nix worker/SSH sessions can outlive service restarts; public-key retirement only
rejects new authentication. Rotation documentation states that boundary.

## Validation and remaining acceptance

Passed configuration evaluation, both production system builds, and the real
two-machine remote-builder test. Both initiators produced overlapping local and
remote outputs. Each peer substituted a fresh unsigned output with local and
remote builds disabled. Wrong pins, shell commands and forwarding were rejected.
The previous client key worked during overlap and failed after retirement; the
replacement remained usable. Peer outage and failed key preparation both left
local builds working. The final fixture runtime was approximately 80 seconds.

The access/access-configuration, secret-reconciliation (13 tests), secret-custody
and auto-update checks passed. Contract syntax/discovery and ADR checks passed;
these are structural evidence, separate from the VM tests. Semantic review traced
the new module through both exports, both fleet consumers, inventory recipient
derivation, runtime publication and updater consumer discovery. No remaining
contract mismatch was found in that scope.

Marshall's complete `mix precommit` passed with 717 tests/properties (64
properties, 653 tests; two host/capacity tests excluded), browser checks and
forced Dialyzer reporting zero errors. A dedicated temporary PostgreSQL instance
kept this run separate from production. ADR/contract checks passed again after
merging the newer upstream documentation without conflict.

## Publication and physical acceptance

Implementation commit `b8a2add` was integrated with updated `origin/main` and
published without force as main merge `84fb6fc776b151e3f1d8bf258ecc65968ddb6188`.
Both hosts independently activated that exact revision and recorded it healthy.
Administrative access and persistent host identities remained intact.

On both hosts, effective configuration has 32 remote slots, automatic local jobs,
zero configured cores (all available), global signature verification, the original
NixOS cache and a root:root mode-0600 runtime client key. Each host successfully
opened its inventory-pinned peer store using the new client key.

A fresh four-derivation batch from each initiator produced three distinct remote
builds and one distinct local build, using the production 32-slot remote pool and
a per-request local limit of one. A smaller one-slot override had scheduled only
local work in one direction and was not used as reciprocal acceptance evidence.
Each direction then built a fresh output locally and fetched it on the peer with
both local and remote builders disabled, proving substitution without rebuilding.
The probes created only unrooted disposable store outputs, with no live identity
or service configuration changes.

Rotation, pin rejection and outage/preparation-failure behavior were exercised
in the two-VM suite; production deliberately did not undergo failure injection.
Neither these bounded probes nor the VM suite establishes service availability
under 32 simultaneous all-core builds. That load limit remains an operational
measurement, not a claimed availability guarantee.

## Addendum 2026-09-21: build delegation deadlock and ADR-0086

Production automatic updates failed in the build phase on every candidate
after this review. Diagnosis on both fleet hosts:

- Overalls and Dungarees poll the same branch on the same short timer, so both
  updaters build concurrently. Each host's Nix daemon filled its local slots
  with the peer's forwarded derivations and delegated new build requests to the
  peer daemon, which delegated them back. Derivations alternated between
  `overalls-builder-dungarees` and `overalls-builder-overalls` in the client log
  without ever executing; network counters showed only protocol handshakes
  while each updater's two-hour command timeout elapsed.
- Wedged daemon sessions held `gc.lock` and the store database lock while
  waiting on the peer, and the updater's child-only timeout kill orphaned
  daemon and SSH sessions that poisoned later attempts.
- Dungarees ran `nix __build-remote` while its own updater was stopped,
  proving the receiver applies its own builder configuration to trusted peer
  requests. This contradicts ADR-0067's assumption that the direct derivation
  protocol does not invoke the receiver's build hook.

Bounded acceptance probes and the two-VM suite passed because they never
saturated local build slots; this review had flagged load under 32 simultaneous
all-core builds as unmeasured. The substituter direction worked throughout.

[ADR-0086](../decisions/0086-reciprocal-nix-caches.md) supersedes the builder
half of ADR-0067: peers stay cache-only trusted `ssh-ng` substituters, every
host builds locally, guest image derivations declare `preferLocalBuild`, the
updater kills timed-out process groups, and host update timers gain a random
start delay. The evaluation and two-machine checks now assert cache-only
configuration and local build placement with working reciprocal substitution.
The production revision was pushed, but rollout remained blocked during secret
staging because the Audi private certificate fields were absent. Fleet health
and absence of peer build dispatch under concurrent updates remain pending live
verification rather than inferred from the configuration checks.
