# Staged detached ingress

## Scope and architecture impact

This review covers [ADR-0192](../decisions/0192-staged-detached-ingress.md),
which amends [ADR-0187](../decisions/0187-detached-ingress-bridges.md)
decision 1 so the browser editor and nested HTTPS use detached ingress
bridges too. It touches:

- the hostd protocol: op 14 `BridgeIngress` gains a preface (at most 4096
  bytes), an expected guest frame (at most 256 bytes) and a ready wait
  (0, or 1..30000 ms with a frame), and hostd stages the guest connection
  with them before starting the bridge;
- Lilly's connector: every ingress service is detachable; the stage is
  derived in `Lilly.Network.Ingress.stage/3`; a detached editor gets a 32 s
  setup budget;
- the editor fleet machine test, which gains a restart-survival subtest and
  a typed browser helper.

`lilly-ingress-bridge`, the scope and slice placement, list/end (ops 15 and
16), records, keepers and re-adoption are unchanged. Domain boundaries,
persistence and Audi's code are unchanged. A follow-up (below) changes
Marshall's editor and web renewal authority after the first machine run.

## Why the editor and nested HTTPS still used op 13 and the BEAM

The task listed typical reasons. Each was checked against the code:

| Candidate reason | Finding |
| --- | --- |
| TLS termination | None in Lilly. Nested HTTPS is TLS from the client to the nested guest; Audi terminates the editor's HTTPS. Lilly carries ciphertext or Audi's plaintext stream opaquely. |
| HTTP inspection | None in Lilly. Audi parses editor HTTP and WebSocket upgrades (`Audi.HTTP.Editor`); Lilly's relay (`pump/3`) moves opaque chunks. |
| Per-request authorization | Audi and Marshall (editor grants, renewal, sign-out). Lilly's part is the execution guardian for the whole connection, which ADR-0187's keepers already hold. |
| Multiplexing | None. Audi opens one connector connection per proxied request or WebSocket. |
| **Setup** | **The actual reason.** `connect/3` writes a Lilly-derived preface (PROXY v2 for nested HTTPS, the framed `EditorConnect` binding for the editor) and, for the editor, waits up to 20 s for the guest broker's framed ready document before Lilly's ready frame goes to Audi. op 14 had no way to do either. |

So the BEAM is essential only for deciding two byte strings and whether the
guest answered correctly, all before the first opaque byte.

## Findings

1. **The stage can run in hostd without moving a decision there.** Lilly
   derives the preface and the exact expected frame from the validated
   binding; hostd writes one and byte-compares the other. hostd interprets
   neither. The exact comparison is narrower than the BEAM's JSON check
   (`IngressConnect.ready?/1`); the broker
   ([`vscode-web-broker`](../../../nix/domains/artifacts/vscode-web-broker/src/lib.rs),
   `ready`) writes exactly the document Lilly expects.
2. **No read-ahead.** hostd reads exactly the expected frame's length with
   non-blocking receives, so any guest byte after the frame stays in the
   socket for the bridge. A different frame, a closed guest or a timeout
   ends setup with no bridge (`hostd-ingress-guest-stage`).
3. **No new authority for a compromised BEAM.** The BEAM could already send
   any bytes to the guest through op 13 and its relay. op 14 still accepts
   only Audi's connection (`ingress-client-is-audi`), and the preface goes
   only to the derived guest target.
4. **Root reads guest bytes, bounded.** hostd now reads up to 256 guest
   bytes into a fixed buffer for the editor. This is a small new surface in
   the root process; moving the stage into the unprivileged bridge would
   remove it at the cost of a second handshake. Recorded as an open
   question in ADR-0192, not a blocker.
5. **Setup time.** A detached editor's dial, cold start (≤ 20 s) and scope
   start run in one hostd request thread (bounded by `MAX_IN_FLIGHT`). The
   BEAM's budget is 32 s and its call bound dial + ready + 10 s. Audi's own
   22 s editor handshake bound is unchanged; the scope start now follows the
   ready frame, so a cold start near 20 s on a loaded host is closer to
   Audi's limit than before (it was already guardian + dial + 20 s).
6. **Records hold the nested client endpoint.** A nested HTTPS binding
   includes the Audi-attested client IPv4 endpoint, so its record in Lilly's
   private 0700 directory does too, until the bridge ends. No credential is
   recorded; the editor binding names the user and account but carries no
   secret.
7. **Wire compatibility.** op 14's layout changed without a protocol version
   bump. Lilly and hostd come from one closure and restart together; an old
   Lilly against a new hostd fails decoding and ends the session.
8. **Sign-out still revokes.** Editor sign-out closes the WebSocket at Audi
   (the authorization subtest); the detached bridge ends when its client
   closes, as for SSH.

## Follow-up: renewal refused after a Lilly restart

The first `vscode-web-nixos-fleet` run failed only the new subtest ("no
editor bridge survived the restarts"). The log showed Audi's renewal after the
Lilly restart answered `unauthorized`, then `audi.editor_revoked`: Marshall,
not the bridge, ended the stream. New admissions succeeded at the same time.

9. **The editor lease pinned Lilly's control session.** Renewal required
   `lease.connection_session_id == host.connection_session_id`; every Lilly
   reconnect opens a new session, so no editor stream could survive a Lilly
   restart. The session is not part of the execution binding (host, VM,
   placement, epoch, generation, account, user), so renewal no longer
   compares it. The lease still records it for audit, and Audi's view is
   unchanged.
10. **Reconnecting was a conclusive refusal.** `Execution.current!/3` denied
    `unauthorized` while the host had no session or an unreported new one,
    affecting editor and web renewal. For renewal only, that state is now
    `temporarily_unavailable` (Marshall's Audi channel: `unavailable`; Audi:
    inconclusive, retried inside the unchanged lease). It is decided last
    (`Execution.renewable!/2`), after login, grant, account, policy, VM state,
    generation and placement checks, so those revocations stay conclusive
    while Lilly reconnects. A stale report on a live session is still
    conclusive, and admission still requires a live, reported session.
11. **Accepted rationale changed.** This narrows ADR-0140's "a replaced
    connection session ends authority at once" for stream renewal, recorded as
    ADR-0192 decision 6 with a reciprocal note in ADR-0140. The exposure is
    bounded: without a reporting session no lease is extended, so an admitted
    stream lasts at most its remaining 30 s.
12. **Not changed, recorded as a gap.** Nested HTTPS renewal (and nested
    `porsche_ssh`/`audi_ssh`) pins the host session through its Inception
    publication and five-second leases, so it cannot ride out a Lilly
    restart; it is not exercised by the failing subtest.
13. **Guest SSH renewal had the same refusal (closed in a second
    follow-up).** `Marshall.Ingress.Sessions` `host!/1` and `ready!/2` denied
    `unauthorized` while Lilly reconnected, so an ADR-0187 SSH session whose
    renewal fell in a Lilly restart window was cut although its bridge
    survived; the user-SSH journey passed only because its renewals missed
    the window. Renewal now accepts a reconnecting host through the
    conclusive checks (gateway, key and owner, write membership, VM state,
    placement, epoch, generation, readiness, start, session binding) and
    then answers `temporarily_unavailable` (`Execution.renewable!/2`).
    Admission is unchanged. Audi's SSH channel already retries an
    inconclusive renewal inside the lease (`Renewal.inconclusive?/1`,
    `retry_after/2`), so Audi needed no change. Porsche does not renew with
    Marshall; nested SSH is finding 12. Recorded as an ADR-0187 correction.

## Execution record (2026-10-17, branch `agent/ingress-https-editor-detached` on `c29e2155b`)

- `lilly-hostd`: `cargo test` 54 passed, including the extended Hegel op 14
  decoding model and the new stage test; `cargo fmt --check` and
  `cargo clippy --all-targets -D warnings` clean.
- `lilly-ingress-bridge`: unchanged; rerun `cargo test` 2 unit and 6
  process-fixture tests passed, fmt and clippy clean.
- Lilly: `ingress_bridges_test.exs` (including the editor/nested HTTPS
  handoff and stage tests), `ingress_execution_test.exs` and
  `network/identity_test.exs` passed (26 tests). `mix precommit` on a host at
  load 37: toolchain, ADR, contracts and Dialyzer (0 errors) passed; the
  suite ran 588/592, failing four timing-sensitive tests in unrelated
  modules (private subscription, guest-trust transport, terminal vsock,
  Inception exchange). Rerun together with the ingress tests, those files
  passed (17 of 17).
- Editor browser helper: the `editorBrowser` artifact (ruff format, ruff
  check and ty against the packaged Playwright) built with `restart.py`.
- NixOS: `overalls` and `dungarees` evaluated.
- Machine tests: not run. The editor fleet subtest "live editor WebSockets
  survive lilly-hostd and Lilly restarts in detached bridges" in
  `vscode-web-nixos-fleet` is the evidence to record.

Follow-up (same branch, on `440cd2bd9`):

- Marshall: `editor_test.exs` and `ingress/access_test.exs` (31 tests,
  including the restart and conclusive-revocation tests), then
  `test/marshall/ingress`, `editor_test.exs` and `ingress_api_test.exs`
  together: 115 passed. Toolchain, ADR, contracts, logging, compile with
  warnings as errors, format, terminal, workspace and monospace checks
  passed. Dialyzer reported one error in the untouched
  `lib/marshall/threads/activity.ex`; `covenant.check --no-run` without a
  preceding full suite run reported the 16 contract obligations as untested.
  The full Marshall suite was not run.
- Audi: `mix precommit` passed (208 tests, Dialyzer 0 errors), including the
  scripted-control renewal tests.
- Machine tests: not run.

Second follow-up (guest SSH renewal, same branch, on `a701ebb28`):

- Marshall: `ingress/sessions_test.exs` 18 passed (1 property, 17 tests),
  including the restart and conclusive-revocation tests; then
  `test/marshall/ingress`, `editor_test.exs`, `ingress_api_test.exs`,
  `ingress_transport_test.exs`, `sharing_surfaces_test.exs` and
  `sharing_matrix_history_test.exs` together: 135 passed.
- Audi: `ssh_transport_test.exs` 19 passed, including the retried
  unavailable renewal; `mix precommit` passed (209 tests, Dialyzer 0 errors).
- Machine tests: not run.

## Remaining gaps

- The editor restart subtest's first run failed on Marshall's renewal; the
  corrected subtest has not run.
- Nested HTTPS and nested SSH renewal across a Lilly restart (finding 12).
- No machine run forces a guest SSH renewal into a Lilly restart window.
- Nested HTTPS has unit and property evidence only; the Inception fleet is
  out of scope.
- The adoption grace and the editor's cold-start margin against Audi's 22 s
  bound are unmeasured on a loaded production host.
