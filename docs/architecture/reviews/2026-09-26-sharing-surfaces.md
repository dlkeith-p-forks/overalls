# 2026-09-26: Combined sharing authority across terminal, SSH and web renewal surfaces

Verification-campaign improvement 101 closes the `sharing` scenario gap: the
combined matrix previously did not prove every shared role across the terminal,
SSH and web entry points simultaneously, and no evidence pinned serialization
between a direct grant revocation and in-flight lease renewals.

Scope executed under discovery-038:

1. One generated direct-role history drives the real terminal ticket/attach,
   SSH roster/open/renewal and private web login/open/renewal surfaces in every
   step, asserted against a closed role/permission table written against the
   generated op model. The oracle never reads `Authorization.allowed?` output.
2. Three independent Marshall BEAMs sharing committed PostgreSQL serialize a
   committed revocation against a committed renewal in both commit orders, with
   pg-observed row-lock waits.
3. A live shared read-only terminal viewer under `Terminal.Sharing.set(:revoked)`
   is pinned against its documented bounds.
4. The native composed fleet journey runs one member with live Audi SSH, a
   shared read-only browser terminal and private web streams, takes one direct
   revocation, and re-shares to fresh admission with new lease artifacts.

## Evidence

### Property: one history, three surfaces, one oracle

`marshall/test/marshall/access/sharing_surfaces_test.exs`
(`property "one generated role history drives terminal, SSH and web entry and renewals"`).

Each generated step applies a real `Access.set_access` role replacement and then
drives, with expectations derived from the model table only:

- terminal: `Terminal.Sharing.set(:shared)` (refused with
  `:recipient_requires_vm_access` for `web`/`revoked`, which lack Cedar `read`),
  `Authority.ticket`, single-use ticket consumption and an actual Viewer
  WebSocket attach/disconnect through the production `TerminalSocket` path. A
  shared member always attaches read-only (zero cols/rows, no input dispatch).
- SSH: `SSH.GuestAccess.roster` (member enters/leaves the writer roster purely
  from the role), `Ingress.open_ssh`, and `renew_ssh` of the same lease while it
  stays live across role changes; a denied renewal is followed by an explicit
  `close_ssh`, after which the same ticket can never renew again.
- web: the full real login exchange (`begin_web_login`, `authorize_web_login`,
  `exchange_web_login`) per step, `renew_web` of the same stream across role
  changes, proof that a cookie minted while allowed cannot reopen a stream
  after withdrawal, and `open_web` for fresh admission. TTLs are asserted in
  `(0, 5000]` at every allowed renewal.

The mandatory sequence `[:operator, :viewer, :manager, :web, :revoked,
:operator]` precedes every generated tail so that collapse to `:revoked` and
re-admission (fresh lease identities) are always exercised. Final assertions:
closed leases never renew, opened session/stream identities are unique, ledger
grant count follows the model, terminal events show exactly one `:shared`
receipt and matching attached/detached pairs, and no input ever left a
read-only viewer.

Focused run: Focused combined suite reported 3 passed (1 property, 2 tests), seed 0, and the neighbourhood suite passed 45 checks, seed 39127
(covering the two pin tests plus access/terminal/ingress/ssh/attachment
neighbours on the same revision).

### Distributed schedules: revoke versus renewal, both commit orders

`marshall/test/marshall/access/sharing_revocation_distributed_test.exs`, five
schedules on three distinct BEAM nodes (independent Repo pools, shared committed
PostgreSQL, coordinator not a peer):

- `renewal_first` for SSH and web: the renewal is gated mid-transaction after it
  holds the VM and lease row locks; the revocation is then observed as a
  pg-blocking-PIDs waiter on the renewal's VM row; on release the renewal
  commits, extends the same lease ID with `expires_at` strictly later yet
  `<= clock_timestamp() + 5s`, and the revocation commits after it.
- `revocation_first` for SSH and web: the revocation is gated mid-transaction
  (grant archived, receipt pending); the renewal then waits on the VM row and
  meets `write`/`web`-denied authority after release; the lease expiry never
  moves.
- combined: one revocation gates while renewals of both surfaces queue — the
  first renewal waits on the revocation's VM row and the second chains behind
  the first through the shared gateway row (`renew_web` takes it `FOR UPDATE`,
  `renew_ssh` `FOR SHARE`); exactly one direct waiter is observed on the
  revocation before release, then both renewals are denied.

After each revocation, every peer's renewal and fresh-open attempts are denied
while the lease is still unexpired on the database clock, so the denial is
authority, not expiry. Ledger snapshots from the third peer prove the
invisibility of uncommitted grant archival.

Five distributed schedules passed in 9.3 seconds, seed 512, and again in 12.0 seconds, seed 9021.

### Terminal pin: revocation of a live shared ro viewer is a documented boundary

`marshall/test/marshall/terminal/sharing_revocation_test.exs`, two tests against
the real `Viewer` WebSocket lifecycle:

- `Terminal.Sharing.set(:revoked)` commits the grant archive and its receipt
  with **no** synchronous relay dispatch (effects record attach only), refuses
  fresh tickets immediately, and keeps the consumed ticket dead. The idle viewer
  then closes by itself through the documented one-second
  `:check_authority` recheck; measured closure is asserted `< 2500ms` and the
  guest session row/stub stay alive (`kill_status == :idle`, no `kill` effect).
  Re-sharing admits only through a fresh single-use ticket and a new relay
  channel.
- A direct VM role revocation (`:revoked`) closes a live shared viewer on the
  same recheck even though its terminal viewing grant row remains; re-granting
  the VM alone re-admits the surviving grant through a fresh ticket.

Defect-candidate verdict: closure through the periodic one-second recheck is the
documented behaviour (`viewer-revocation-is-live`: "idle/output-only viewers
MUST also recheck every second"). Both pin tests reproduce the candidate and
find it within documented bounds with measured margin; no repair was needed.

### Full Marshall suite

1195 passed (139 properties, 1056 tests), 2 excluded, in 795.4 seconds with the
three new suites included (`mix test --include distributed`), catalogued
`MIX_TEST_PARTITION=verify101` isolation.

### Native composed fleet journey

`nix/verification/tests/machines/fleet/scenarios/sharing-surfaces.py`, registered as the
explicit Nix check `sharing-surfaces` (HEAVY lock class; nine QEMU machines:
three Marshall replicas, one PostgreSQL/mod chrony node, three-replica HAProxy,
two Lilly hosts with nested Firecracker, a browser/SSH client and the egress
fixture). The browser/JavaScript artifacts pass the pinned `ty`/`tsc` gate in
the registered `sharingSurfacesBrowser` artifact; the scenario fragment passes
standalone `ruff format`/`ruff check`.

`TO BE FILLED` — execution record lands in this document after the native run of
`checks.x86_64-linux.sharing-surfaces` completes; the scenarios.json machine row
is promoted to `recorded` in the same change.

## Mutants

| Mutant | Intended oracle | Result |
| --- | --- | --- |
| `Ingress.Sessions.perform(:renew_ssh)` Cedar action `write` → `read` | combined property: a denied-role step must stop a live SSH renewal | Detected and reverted: `SSH renewal must follow the model` fired with a wrongly-allowed renewal; seed 0 |
| `Ingress.WebStreams` renewal authority `web` → `read` | combined property: a `web`-role step must retain web admission | Detected and reverted: `web renewal must follow the model` fired with the wrongly-forbidden renewal; seed 0 |
| `Terminal.Sharing.set` recipient VM-read precondition dropped | combined property: sharing to a `web`/`revoked` recipient must stay refused | Detected and reverted: `terminal sharing must require recipient VM read` fired; the existing terminal sharing suite also caught it; seed 0 |
| `Terminal.Viewer` `@authority_interval` 1000 → 60000 | pin test: revocation closure must stay under the one-second recheck bound | Detected and reverted: both pin tests fail waiting for the viewer close frame; seed 0 |

## Remaining gaps

- Native composed evidence runs on the NixOS nested-guest fleet with two Lilly
  hosts; native Ubuntu guests, independent physical hosts and production
  DNS/ACME issuance remain outside the composed journey and retain their
  separate evidence.
- Distributed schedules prove serialization on one shared PostgreSQL clock;
  multi-region clock failure domains stay outside this campaign's scope by
  direction.

## Architecture impact

No runtime, protocol, authorization, persistence or schema change. All new
verification composes existing accepted decisions: persisted Cedar role as the
single sharing authority, per-surface live renewal bindings with five-second
TTLs (existing ingress contracts), the terminal viewer one-second recheck
contract, and disposable three-BEAM schedule fixtures under the shared-PostgreSQL
boundary inherited from the 001/012/019/022 campaign families. No ADR text was
touched; no new architectural decisions were needed.
