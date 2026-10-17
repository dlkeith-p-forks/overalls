# Local console gate review

## Scope and evidence

ADR-0020 implements Lilly's local terminal primitive under ADR-0019. It adds a
durable input-attempt watermark, owner-bound console process, local elapsed-time
checks and bounded output. It changes no remote protocol or runtime startup yet.

## Findings and resolution

- **High, corrected duplicate-input risk:** acknowledgment loss cannot establish
  whether a guest received a command. The journal records an attempt before socket
  delivery. A replay of that sequence is suppressed after reopening; lost input
  is reported as uncertainty rather than automatically repeated.
- **High, corrected stale-authority risk:** using response-arrival time extends
  stale authority. Validity is capped from local request start, checked after
  persistence and before input delivery. Pending claims and stale response sequences
  cannot grant writing. Runtime integration must supply trusted local timing.
- **Medium, corrected memory risk:** output uses active-once socket delivery and
  a copied 64 KiB suffix, with 16 KiB pages and explicit cursor gaps. A fresh
  incarnation identifies restart loss. There is no unbounded console transcript.
- **High, corrected diagnostic leak risk:** terminal bytes can appear in messages,
  termination reasons and call-exit arguments even when state is redacted. The gate
  redacts these surfaces and returns fixed errors to its owner.
- **Open integration requirement:** a private directory lock is local to that
  canonical path. The VM actor must choose it, verify the current VMM generation,
  own the gate, and bind the authenticated host connection. No browser or network
  endpoint exposes this primitive yet.

## Verification

The focused console run passed 14 cases using real Unix sockets and private durable
files. Lilly's suite passed 75 cases (17 properties, 58 tests). Review tightened
integer validation to reject float lookalikes; Dialyzer identified a now-unreachable
zero comparison, which was removed. Final Lilly precommit passed, including Dialyzer
with zero errors/exclusions, and its production release rebuilt successfully.
Marshall precommit also passed 121 cases (8 properties, 113 tests) and Dialyzer with
the existing single upstream exclusion. No new exclusion was added. The structural
ADR check validates 20 records. Protocol code did not change.

The real three-guest KVM harness passed. Its console probe verified that duplicate
input changed guest state once, pending/expired/old-epoch input was denied, a hard
gate kill preserved the VMM, and a replacement gate restored the input watermark
and suppressed replay. The existing confinement, Internet, six directed VM-isolation
paths, spoofing, persistent stop/start and deletion-cleanup checks also passed.
Control frames in this probe are simulated; it does not prove remote user access.
The harness removed its units, mounts, disks, TAPs, namespace and firewall tables;
the test slice was stopped afterward, and the host has no remaining Lilly units,
network namespaces or nftables tables.

## Limits and follow-up

Complete and test the remote transport and physical runtime integration. Local
checks are not an end-to-end revocation guarantee. Input accepted before a fence
cannot be undone, and a guest command's execution is outside the transport's
at-most-once attempt guarantee. Tests must not hide restart gaps or ambiguous
delivery by silently replaying input with a new sequence.
