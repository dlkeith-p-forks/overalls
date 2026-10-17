---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
---

# G5: SSH, DNS, and personal editor access routes

This targeted discovery addresses coverage-balance finding 5. These six source-grounded candidates are proposed for catalog synthesis; none is an implemented assertion, reproduced defect, or passing current run. The existing private-web lease, current-membership, GuestAccount and terminal rows do not observe strict SSH host trust, authoritative DNS answers, or a personal editor's saved file. Each proposed primary SDK message is unique in the current catalog. No source, existing catalog, or property file was edited.

| Candidate | Type / priority / literal primary SDK message | Independent proof |
| --- | --- | --- |
| [strict-ssh-host-trust-reaches-current-guest](access-routes/strict-ssh-host-trust-reaches-current-guest.md) | Safety, P0, `Always`: **"Strict SSH host certificates reach only the current guest execution"** | OpenSSH with the installed CA and strict checking, actual Audi/guest certificate chain, remote boot/UID/file nonce, and current placement; wrong principal/CA or stale route must not produce guest bytes. |
| [revoked-ssh-key-refuses-fresh-guest-login](access-routes/revoked-ssh-key-refuses-fresh-guest-login.md) | Safety, P0, `Always`: **"Revoked SSH key cannot open a fresh guest login"** | Public key removal followed by a new signed SSH attempt; no remote command nonce or new current guest-login row, with a different valid key as a positive control. |
| [authoritative-dns-follows-current-placement](access-routes/authoritative-dns-follows-current-placement.md) | Safety, P0, `Always`: **"Authoritative DNS addresses follow the current published placement"** | Raw UDP/TCP authoritative A answers at each Audi replica, compared with current route's gateway addresses and an HTTPS/SSH target effect after convergence; stale route does not masquerade as a successful answer. |
| [editor-save-survives-worker-recovery](access-routes/editor-save-survives-worker-recovery.md) | Safety, P0, `Always`: **"Personal editor save survives worker recovery under its owner's UID"** | Pre-fault guest-file bytes, a browser save of a fresh marker, guest filesystem hash/UID, and a new editor read after broker/worker loss or stop/start. |
| [editor-login-code-single-use-after-reply-loss](access-routes/editor-login-code-single-use-after-reply-loss.md) | Safety, P0, `Always`: **"Editor login code creates at most one credential after reply loss"** | Concurrent real callback redemption and committed login/credential count despite response loss; one successful first exchange is the positive control. |
| [editor-signout-fences-active-guest-write](access-routes/editor-signout-fences-active-guest-write.md) | Safety, P0, `Always`: **"Signed-out editor session cannot write new guest bytes"** | Ordinary browser sign-out, live WebSocket closure, old cookie refusal and absence of a post-sign-out marker in the guest; fresh sign-in is the positive control. |

## Boundaries and synthesis notes

`strict-ssh-*` checks certificate trust and an actual SSH guest effect after route selection; `revoked-ssh-*` tests user key revocation on a fresh attempt. Neither treats a certificate as user authorization. `authoritative-dns-*` checks the DNS response bytes and route destination; a healthy Marshall projection alone cannot pass it. Editor save is a filesystem effect, code exchange is single-use browser authority, and sign-out fences a previously active stream; none is established by generic private-web or terminal rows. The prior `relocation-handoff-one-current-execution` property can be correct while these public routes are unusable.

Hosted `access` can prove gateway refusal without a guest. Successful SSH/editor byte claims require the `guest-journey` TCG guest with real boot, TCP 4444 broker and host-to-guest vsock peer CID **2**, or a current native KVM fleet run. CID 2 is the host peer seen by guest vsock listeners; it is not a guest identity or evidence of Firecracker isolation. Every success witness must correlate VM, host, placement, execution epoch, generation, host session, and kernel boot UUID with the current authority; do not infer physical execution from an API status. TCG's QEMU/backend/overlay process receipts are emulated-process evidence only. DNS requires an actual authoritative UDP or TCP answer; an API JSON snapshot is supporting evidence only. Timeouts, SERVFAIL and unavailable authority are distinct from an observed stale A record or denied write.

Faults are useful only at their real boundaries: Marshall/DB and Audi/replica interruption for route propagation; source/destination Lilly or guest process interruption for SSH handoff; Audi, broker, worker and guest restart for editor. A quiet recovery window and ready current services are preconditions for conditional progress probes. Tenant process/clock fault availability is unconfirmed. No current hosted image, baseline, mutation, native acceptance receipt or Antithesis assertion exists for these candidates. Existing Nix driver source suggests fixture design, not current passing execution. Suspected route or renewal races remain hypotheses until a discriminating reproduction.

## Investigation log

- Read root and Antithesis `AGENTS.md`, Marshall guidance, architecture overview and ADR index; ADR-0124, ADR-0153, ADR-0158 and the current Antithesis/editor/SSH/ingress/Audi/Porsche contracts; Antithesis research discovery, catalog, claim-validation guidance; `sut-analysis.md`, `deployment-topology.md`, `property-catalog.md`, and `evaluation/coverage-balance.md`.
- Traced the source and test paths cited in each candidate. The authoritative DNS response, strict OpenSSH chain and guest file effects are independent observations; stored route or service events alone are insufficient.
- Architecture/HLDD impact before and after this research-only diff: none. It changes no decision, behavior, configuration, protocol, implementation, handbook claim, or verification result. The open implementation questions and required current-run receipts remain in the evidence files.
