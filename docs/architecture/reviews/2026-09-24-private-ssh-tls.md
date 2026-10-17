# Private SSH TLS verification review

## Scope and production evidence

This review covers ADR-0111's certificate names and the guest SSH authority
client under ADR-0110. A newly created production Cedar VM reached Audi's
private address but could not start its SSH listener: its helper emitted
`ssh.authority_connect_failed` while fetching the roster. A diagnostic Rust
client using the same trust bundle reported `MalformedDnsIdentifier`. The
deployed leaf includes `*.internal` before `*.integration.internal`, under an
intermediate constrained to `.internal`. OpenSSL accepted the chain and exact
`ssh.integration.internal` name; Rustls rejected the malformed broad name.
This is a certificate parsing difference, not an Audi routing or user-key
authorization failure.

## Decision and boundary assessment

ADR-0111 supersedes ADR-0078's SAN set for future offline issuance. The
certificate continues to be a single fleet leaf signed by the recovery-only
issuer and distributed as encrypted host secrets. The private endpoint, guest
root bundle, exact hostname check, no-proxy and no-redirect settings, and
fail-closed SSH roster policy remain. The Linux SSH helper selects native TLS
to verify the currently deployed leaf; Lyra's other HTTPS clients select
Rustls explicitly. A client certificate or hostname mismatch still stops the
roster from being accepted. Neither this change nor the new SAN set expands
which guest, account, or key Audi may authorize.

The offline issuer and shared protocol now request only `llm.internal` and
`*.integration.internal`. The fleet machine-test fixture now has a
name-constrained intermediate and that same leaf name set. This makes the
guest SSH test exercise the chain structure that exposed the production fault.
No Ash resource, Oban job, audit event catalog, or persistent authorization
schema changes in this correction.

## Verification and remaining gaps

The native-TLS helper built as a static Linux binary. In a network namespace
with the production root bundle, it completed the private TLS handshake and
received the expected authorization denial for an unbound host process. The
same helper was installed only into a disposable production VM for acceptance.
Using the normal Audi SSH route, an authenticated user reached
`geoffrey.huntley`, saw `/home/geoffrey.huntley`, wrote a home-directory file,
and read it again after a Porsche relocation from Overalls to Dungarees. The
post-handoff `whoami`, `pwd`, home-file check and `ls` succeeded. Marshall's
durable guest-login audit rows and Audi's structured open event matched the
VM and placement.

Both NixOS and Ubuntu fleet journeys passed after extension to the complete
Porsche create, Kittens SSH, Porsche relocation, and Kittens SSH sequence. Each
checked `whoami`, `pwd`, home ownership and mode, `ls`, a pre-move home file,
a post-move interactive shell, and the new placement's durable login audit.
The Audi PKI tests, four-target Lyra package build, Lyra unit/property tests,
Python static checks, protocol gate, and Marshall gate passed. Lilly's gate
reached its Dialyzer check with zero errors but one timing assertion failed
during concurrent Nix builds; the focused rerun passed.

The deployed leaf has not been rotated because its recovery-only signing key
is unavailable in this session. Existing guest disks, including the originally
reported VM, still lack the corrected helper and need a data-preserving
upgrade. An off-host recoverable backup destination is not yet configured.
The disposable VM's relocation served SSH after handoff. Its subsequent
deletion initially retried because ZFS reported the source dataset busy, then
Lilly recorded `lilly.zfs_destroyed`, `lilly.cleanup_completed` and `vm.deleted`.
The source dataset was absent on a later native query, and Porsche no longer
exposed the VM. The certificate rotation and older-disk migration obligations
keep ADR-0111 partially implemented.
