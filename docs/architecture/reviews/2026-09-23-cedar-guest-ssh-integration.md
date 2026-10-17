# Cedar guest SSH integration review

## Scope and architecture impact

[ADR-0110](../decisions/0110-cedar-guest-ssh-accounts.md) replaces the
provision-time root key in [ADR-0093](../decisions/0093-audi-mediated-guest-ssh.md)
and changes the developer profile from
[ADR-0096](../decisions/0096-lyra-developer-ssh.md). The shared VM command
protocol, Marshall account and ingress persistence, Ziggy's private relay,
Audi's private frontend, Lilly's customer firewall, both guest images and Lyra's
installer change together. [ADR-0011](../decisions/0011-nixos-guest-and-console.md)
retains its terminal and serial decisions; its later root SSH amendment is
historical.

## Authorization and isolation

The guest obtains a VM-bound roster and fresh key decision over the existing
private certificate hierarchy. Audi selects `ssh.integration.internal` and
Ziggy carries the host-derived physical binding to Marshall. Marshall checks
the provisioner credential, live host/placement/execution, registered offered
key, active Audi SSH session and current Cedar write permission before returning
a key. Customer egress permits the fixed DNS/TLS private service only. A failed
lookup or control-plane outage denies a new guest login. Audi's independent
session lease remains the authority for closing existing SSH streams after key
or share revocation.
The destination fetches a roster before relocation readiness, using the exact
physical host, placement, epoch and completed start operation. Readiness still
gates key authorization and login. This ordering lets the guest start sshd so
the relocation readiness probe can finish without permitting an early login.

The helper sends HTTPS requests directly from Rust with a bounded explicit CA
bundle, a fixed route set, Lilly's fixed private endpoint, disabled proxies
and redirects, a three-second
deadline and bounded response reads. Hegel properties cover response bounds and
HTTP status acceptance, duplicate identity, public-key proof and safe home
components; a unit test checks redirect refusal. The Nix package
vendors the locked TLS dependency for every shipped target.
NixOS publishes the callback binary at a root-owned `/run` path before sshd
starts because OpenSSH rejects executable paths beneath the group-writable
Nix store root. The Ubuntu image installs its callback in `/usr/local/bin`.
Both images publish a boot-local readiness marker only after a successful
roster sync. The SSH listener checks that marker at startup, while a later
successful sync can start a skipped listener. The listener does not require
the sync unit, avoiding a recursive start transaction.

Marshall reserves the exact lowercase email local part and a never-reused UID
for each account incarnation. The Rust helper validates a bounded roster before
changing local users, provisions mode-0700 homes and sudo policy, and disables
revoked accounts without deleting homes. A roster sequence and digest reject
stale or conflicting replay. Users with VM write permission receive passwordless
sudo; their homes are therefore convenience and attribution boundaries rather
than isolation against another writer.

The PAM hook reports a post-authentication key and Marshall persists a
`GuestLogin` row. It is a **guest-reported** audit event: a guest administrator
can forge it. Marshall's key-linked SSH session record proves outer admission;
Audi emits `audi.ssh_open` only after its local guest connector succeeds.
Neither event alone proves guest user login. Eligibility probes never create
login rows. Reviewed Elixir Events
catalogs and fixed JSON helper events keep key material, credentials, commands
and terminal bytes out of diagnostic logs.

## Recovery and compatibility

Guest account state and homes persist on the VM disk. A newer roster reconciles
memberships after a restart; an authority outage refuses new key decisions.
Existing pre-Cedar disks, whether or not they received a provision-time root
key, need replacement or an explicit migration before they can serve Cedar SSH.
This change deliberately removes its wire and guest image paths. The nullable
database column remains inert because the automatic updater applies migrations
before stopping the old Marshall release; dropping it in this release would
break old readers during the switch. A later coordinated schema cleanup can
remove it after every host runs the new code.

The [host recovery facility](../../backups.md) includes the database ciphertext,
separately protected Cloak keyring and VM disks, but production backups are not
enabled on Overalls or Dungarees. Neither host has a backup service or status
record, and the host declarations have no backup credential. An operator must
supply the S3 destination and encrypted per-host credentials before recovery
points can be claimed for the existing VM or the wildcard keys.

## Verification and remaining gate

Marshall's merged full precommit passed with 926 tests, including 73 properties,
and zero Dialyzer errors. Its guest access property changes each physical
binding field against a live Audi session and checks denial without a login
audit row. Protocol and Lilly precommit passed with 200 and 389 tests,
including 71 and 43 properties, and zero Dialyzer errors. Audi and Ziggy suites,
Rust tests and Clippy, the Nix Rust test derivation, repository logging/Python
gate, ADR checking, code contracts, private-services network machine test and
both guest image builds passed. The merged full NixOS Audi fleet passed, including
native SSH, separate homes, login audit, key and share revocation, live stream
closure and recovery. The merged full Ubuntu Audi fleet also passed, including native
SSH, Customer profile behavior, key revocation, isolation and recovery.
Both production host deployment bundles built locally. Both fleet updaters
activated the Cedar implementation and later recovery fixes and reported the
release healthy. A live attempt to the previously reported VM reached Audi and
Marshall opened a session, but Lilly's local connector denied the guest socket.
The VM was created before Cedar, has no provision-time key, and a marked,
TAP-bound TCP connection to its address returned `ECONNREFUSED` on port 22.
Its existing disk needs replacement or an explicit migration to the new guest
image before Cedar SSH can work. That replacement is not performed by a host
release update. Relocation ownership and live share-revocation closure now have
dedicated machine assertions. A separate user journey check exercises Porsche
key registration, native VM creation, Kittens CLI setup and an interactive
shell with the email-derived username and home, plus ordinary `whoami` and
`pwd` remote commands through the same generated profile. The host-key fixture
only reads the guest's public key; it does not start roster sync or sshd, so
the first successful SSH command proves boot-time service activation.
The authorized Porsche VM view now returns `ssh_host` from the persisted Audi
endpoint and configured zone; its existing `host` field remains the physical
provisioner. The first journey run found this missing user-facing name before
client setup. The next run exposed an incorrect test expectation about the
existing `v-` ingress-label prefix; the assertion now matches the persisted
endpoint name and full immutable VM UUID. The complete fresh NixOS journey
subsequently passed with Porsche key registration, Porsche VM creation, native
Kittens CLI setup, `whoami`, `pwd`, mode-0700 home ownership, an interactive
PTY shell and a durable guest-login row. The fixture obtains the public guest
host key without starting guest SSH units. The same complete journey passed
against the Ubuntu guest image.

The first NixOS and Ubuntu relocation runs exposed a readiness cycle: the
destination SSH listener waited for its roster, while Marshall withheld that
roster until readiness. The guest access change permits roster bootstrap after
exact physical activation and preserves the readiness gate for key decisions.
The targeted relocation unit test passed. The complete NixOS and Ubuntu
relocation machine checks subsequently passed with a real Firecracker guest
move and unchanged nested strict SSH profile.
The relocation machine test now reconnects with the unchanged strict profile
and runs `whoami`, `pwd`, `ls` and a persisted home-file read after the move.
It also checks the destination-bound login audit row. A prior test attempted
to write a retention marker under `/root` as the unprivileged user and masked
the write failure with a later `sync`; the new checked marker write uses the
user's own home.

The final acceptance commands passed:

- `nix build .#checks.x86_64-linux.user-ssh-journey-fleet --no-link`
- `nix build .#checks.x86_64-linux.user-ssh-journey-ubuntu-fleet --no-link`
- `nix build .#checks.x86_64-linux.audi-relocation-fleet --no-link`
- `nix build .#checks.x86_64-linux.audi-ubuntu-relocation-fleet --no-link`

Lyra's outer Audi key lookup, CLI update, browser-approved agent CLI and guest
agent RPC now share a bounded Rust HTTPS client. The client verifies TLS,
disables proxies and redirects, caps streaming responses and keeps bearer
headers in memory. Rust unit and Hegel tests cover URL, host-key line and body
boundaries. The installer also derives public keys from local private keys when
there is no `.pub` sibling, then selects the exact matching private identity.
A generated Marshall SSH profile now calls Lyra's Rust `host-key` command for
its current gateway key through the absolute `/usr/bin/env` entry point required
by OpenSSH, including each nested gateway layer. Its exact HTTP
status, response size and host binding checks fail closed, and the generated
profile requires the installed `kittens` CLI on the developer machine.
A strict live Porsche proof succeeded with this machine's key and the refreshed
profile selects `geoffrey.huntley` with that key. This preserves ADR-0110's
authority and audit boundaries without a protocol change. The old VM's missing
listener remains a guest-disk migration gap, not an Audi authorization failure.

## 2026-09-24: nondefault client key follow-up

A macOS user configured the Kittens profile successfully but the nested Audi
connection reported `Permission denied (publickey)` for a production Customer
VM. The installer selected the registered key for the guest `IdentityFile`, but
Lyra's Rust proxy launched a separate SSH process with `-F /dev/null` and no
identity option. That process could offer only default or agent-chosen keys.
There was no corresponding gateway session for the reported attempt. This is a
client transport defect within ADR-0110, distinct from the guest's own key
decision.

The proxy now receives the setup-selected, bounded `.ssh` filename through its
managed profile, validates it as one filename, and starts the outer SSH process
with its absolute path and `IdentitiesOnly=yes`. The inner SSH process retains
the same selected identity. Rust unit and Hegel tests cover identity filename
validation and the outer command options. The user journey fixture now uses a
nondefault private-key filename without a `.pub` sibling, exercising the exact
failure path through Porsche, fresh Firecracker VM creation, Kittens setup and
guest SSH. The revised NixOS and Ubuntu native journey checks passed. Production
rollout reached `healthy` on both Overalls and Dungarees at revision `d3d63711`;
the published macOS and Linux artifact digests matched the built Lyra package.
The later network-lock follow-up reached `healthy` on both hosts at `f3d8d1af`.
The user's Mac must rerun the installer to replace its previously installed
client and managed SSH profile.

The Customer VM's Marshall observation also alternated between `running` and
`unknown`, independently denying some Audi grants before guest connection. The
[Lilly adoption retry review](2026-09-24-running-vm-adoption-retry.md) records
that correction. Neither client fix nor Lilly reconciliation automatically
upgrades a guest disk created from an older image; guest listener availability
must be checked on the production VM after rollout. A host-side probe of that
Customer VM's guest address on port 22 found no reachable listener before this
rollout. Its root disk was created from an image registered before the Cedar
guest SSH release. The image's `sshd.service` requires the old `lilly-ssh.service`,
which has `ConditionKernelCommandLine=lilly.ssh_key`; it has no Cedar roster sync
unit. A second host-side port-22 probe after rollout still found no listener;
Audi recorded a connector failure on a live SSH attempt after client key
authentication. The VM must remain intact until its data can be preserved and
the guest can be upgraded or migrated; publishing a new client binary alone
cannot make this existing guest accept SSH.
