# Composed sharing matrix verification

## Scope and architecture assessment

Improvement 054 begins at `c14ae27d` in its own worktree and branch
`verify/054-sharing-matrix`. The campaign scenario ledger recorded the gap
"the combined matrix does not prove every shared role across every terminal,
SSH and web entry point simultaneously". Improvements 016 (integration
renewals), 021 (private web) and 025 (terminal attachments) each recorded
renewal and withdrawal subsets for their own entry; none composed every
shared role across all three entry paths in one generated history. This
improvement closes that composed gap at the application layer with one
generated role × entry-point matrix family and a three-peer distributed
schedule family.

Architecture impact: verification and evidence maintenance only. The change
adds two ExUnit modules and one test-support fixture module under
`marshall/test/`; no production module, Cedar policy, schema, protocol,
authorization rule, service placement or dependency changes. ADR-0077
(private web sharing), ADR-0083 (terminal attachment modes) and the access
membership contracts in `marshall/lib/marshall/access/CONTRACTS` are
exercised, not altered. The independent matrix literal restates the accepted
Cedar permission table rather than redefining it; a mismatch is a test/code
finding to reconcile, not a silently rewritten decision. No new native or
Inception validation is claimed.

## Pre-implementation record

- **User operation.** A VM owner shares a machine with a collaborator under
  one current role (`viewer`, `operator`, `manager`, `web`), demotes or
  revokes it; the collaborator independently opens terminal sessions and
  one-use tickets, opens and renews Audi SSH sessions, authorizes and
  exchanges private web logins, opens and renews private web streams, and
  reads VM inventories.
- **Allowed result.** Decisions follow the independent literal matrix:
  `manager` and `operator` receive inventory, terminal read and write, SSH
  and web; `viewer` receives inventory, read-only terminal and web; `web`
  receives only private web; `revoked` receives nothing. Terminal ticket
  mode is `rw` exactly when the current role retains write.
- **Refusal.** Every refused entry rolls back with a byte-identical scoped
  durable inventory: VM rows, placements, operations, reservations, access
  grants/changes/versions, terminal sessions/openings/sharing grants and
  versions, ingress endpoints, SSH sessions, web streams, web logins, web
  credentials and their versions, plus the member's SSH key and its
  versions. Terminal ticket rows and terminal events remain documented
  mutable receipts outside the refusal oracle, matching the recorded 025
  terminal attachment scope.
- **Failure and recovery.** Withdrawal through one ordinary
  `Access.set_access` (`role: :revoked`) refuses SSH renewal and opening,
  web approval/exchange/opening/renewal, terminal open/ticket and inventory
  reads; an approved-but-unexchanged web login refuses exchange; ordinary
  explicit closes succeed exactly once per lease; closed tokens never revive
  after re-grants; a `web`-only re-grant reopens web flows alone; a
  `manager` re-grant reopens terminal and SSH for fresh entries only. Grant
  churn interleavings across two machines of one owner keep each machine on
  its own matrix cell.
- **Independent property oracle.** The `@matrix` literal in
  `sharing_matrix_history_test.exs` and the equivalent literal in
  `sharing_matrix_distributed_test.exs` derive every expected decision from
  the generated role history alone; neither consults Cedar, Ash policies nor
  `Marshall.Access.Authorization`.
- **Native boundary.** Documentation-only, justified: the composed matrix
  boundary is the application-layer Cedar role derivation at every entry,
  which the generated histories exercise against SQL-backed implementations.
  Native transport closure for each entry was already recorded: 016's
  captured `4sdl4ki` journey (live membership/attachment withdrawal),
  021's captured `c3d08d59` journey (nine stages including original
  HTTP/WebSocket closure, fresh 403 and fresh recovery) and 025's retained
  013 journeys (sharing, writer refusal and grant/login revocation in real
  guests). This improvement does not rerun or broaden those native results.
- **Dependencies.** None hard. Fixture and schedule patterns reuse the
  established terminal/ingress fixtures, `CommittedFixtureCleanup` and
  `CommittedFixtureInventory` from 029; no 016/021/025 evidence is
  duplicated.
- **Required checks.** Focused suites with seeds including the distributed
  schedules, the full Marshall precommit, all-file prek, ADR, HLDD and
  generated-reference gates, and the Nix HLDD check.

## Independent oracle and one generated history

The property "every shared role composes terminal, SSH and web entries in
one generated history" creates a fresh committed VM/host/ingress fixture per
run (earlier runs' hosts are disabled inside the sandbox to pin placement)
and walks a mandatory role ladder — `manager → viewer → operator → web →
revoked → viewer → manager → revoked` — followed by a generated role tail.
After every ordinary share mutation the step asserts, against the literal
matrix:

- read inventories: `Compute.list_vms` membership and `Compute.get_vm`;
- terminal: `Authority.open_session`, one-use ticket issuance, consumed
  mode (`rw` only with current write) and `Authority.writable?`;
- SSH: `Ingress.open_ssh` and `renew_ssh`;
- private web: gateway `begin_web_login` (a precondition outside the
  member-visible matrix), then `authorize_web_login`, `exchange_web_login`,
  `open_web` and `renew_web`;
- stale leases: a live SSH or web lease renews exactly when the current role
  retains the capability, otherwise renewal refuses, one ordinary close
  succeeds and the token never renews again, including after re-grants;
- inventory equality: every refusal is bracketed by the complete scoped
  durable inventory, computed in a single aggregate query per refusal and
  required to be byte-identical.

The fixed withdrawal test composes all entries live simultaneously under an
`operator` grant — an rw terminal ticket, one SSH lease, one private web
stream and one approved-but-unexchanged login — then performs exactly one
ordinary revocation and asserts every derived entry refuses while explicit
closes still succeed once, the approved login cannot exchange, and later
`web`-only and `manager` re-grants restore precisely their own entries
without reviving closed tokens.

The churn property provisions a second machine on the same host, interleaves
generated `{first | second, role}` mutations, and asserts the full matrix on
both machines after every mutation, proving one actor's grant churn never
leaks between machines.

## Distributed schedules on three peers

`sharing_matrix_distributed_test.exs` starts three fresh Marshall BEAMs with
separate Repo pools and Cedar handles sharing only committed PostgreSQL; the
runner is not a replica. The fixed schedule mutates the share on one peer
and observes SSH opening/renewal, web begin/authorize/exchange/open/renew
and inventory reads on the other two, then demotes and revokes across peers:
SSH closes everywhere while web survives the demotion, and one committed
revocation closes renewal and reopening on every peer with explicit closes
succeeding once and closed tokens never reviving. The generated schedule
property places each mutation and each entry probe (`ssh_open`,
`web_authorize`, `inventory`) on arbitrary distinct peers decided by the
independent matrix. The terminal entry keeps its positive composition in the
sandboxed properties and 025's socket-level evidence: on peers only the
refusal direction is asserted (`open_session` denies `:forbidden` for a
demoted member), because the synthetic relay stream is local to the parent
node.

Both distributed journeys run inside `Cleanup.protect` and restore the
complete committed database, verified independently by
`CommittedFixtureInventory.assert_restored!/1` including fixed fixture image
ownership; the tests refuse to start placement if any enabled committed host
predates them rather than silently mutating it. The fixed withdrawal test
fences the three peers on failure per the reviewed cleanup contract; because
every generated schedule RPC is serially awaited, the property instead keeps
peers alive across iterations so a failing value retains its original
counterexample evidence. Host freshness is renewed immediately before each
entry probe so the five-second capacity-freshness window cannot expire
between a mutation and a loaded peer call.

## Mutant cycle

The renewal-derivation mutant replaces `Authorization.live_vm!`
current-`write` re-derivation in
`Marshall.Ingress.Sessions.perform(:renew_ssh, ...)` with a bare VM read,
simulating a renewal that skips role re-derivation. With the mutant, the
history suite reported **0/3 passed (0/2 properties, 0/1 test), seed
`54054`**: the stale-lease oracle's `assert {:error, _} = fun.()` in
`denied/2` observed `{:ok, _}` for a renewal after write authority was
withdrawn, in both the composed history property and the one-withdrawal
test. The production source was restored byte-for-byte with `git checkout`;
the focused history and SSH session suites then passed **18 checks (3
properties, 15 tests), seed `54054`, in 40.6 seconds**.

## Execution evidence

Focused executions, all with `ERL_FLAGS='+S 4:4'`,
`MIX_TEST_PARTITION=verify054` and the campaign PostgreSQL socket:

- Composed history suite `sharing_matrix_history_test.exs` passed 3 checks
  (2 properties, 1 test) on the corrected source: seeds `54054` (26.9
  seconds), `26001`, `99012` and `777`, all passing. Review anchor:
  sharing-matrix history passed 3 checks. Repeat runs
  exposed two fixture defects, not product defects: per-step durable
  inventories initially used 24 sequential queries, letting step latency
  approach the five-second SSH/web lease TTLs, and per-property fixture
  reuse hit the 64-session terminal cap; the inventory is now one aggregate
  query and fixtures are per run, matching the recorded 025 placement
  lesson. One run subsequently exceeded the 120-second sandbox ownership
  ceiling at 12 runs; runs were reduced to 6 per property (matching 025)
  with the full role ladder retained per run, and a wrongly parenthesized
  renewal-cancel repair attempt was discarded as unmerged fixture noise.
- Distributed suite `sharing_matrix_distributed_test.exs` passed 2 checks
  (1 property, 1 test) on the corrected source: seeds `4141` (5.5 seconds),
  `9090` and `271828`, committed inventory restored in each. Review anchor:
  sharing-matrix distributed passed 2 checks. Two honest defects of this
  improvement's own test code were caught by the full gate, not by argument:
  (1) the distributed literal oracle omitted the viewer → web edge that the
  Cedar policy grants, surviving two focused seeds whose generated schedules
  never crossed viewer × web authorize, until a precommit gate counterexample
  (`{:viewer, 0, 0, :web_authorize}`) exposed the mismatch — the SUT correctly
  allowed and the literal was corrected, with mandatory prefix edges added for
  every role × entry pair so the family cannot skip such an edge again;
  (2) an unknown test typespec name (`Credentials.t/0` for the nested
  `Credentials.Issued.t/0`) was caught by Dialyzer. Neither was a production
  defect, and the first full-gate pass at seed `466058` (1,192 checks)
  predates both corrections, so it is retained here as an intermediate record
  only; the final gate evidence below is measured on the corrected tree.
- Neighbourhood suites together (`access/`, ingress sessions/access/private
  history, terminal attachment history): 49 checks (17 properties, 32
  tests), two excluded, seed `64001`, 116.4 seconds. Terminal open/ticket
  and socket lifetime evidence remains 025's scope.
- Full Marshall test gate recorded below under final review.

## Existing evidence retained

The 016 integration renewal review, the 021 private web review and the 025
terminal attachment review retain their exact recorded scopes; this
improvement generalizes their per-entry property approach into the composed
matrix rather than duplicating their evidence. The native Audi SSH
revocation scenario and existing Cedar sharing property stay listed on the
scenario row. Team-membership matrix cells, administrator elevation paths
and Customer profile isolation remain in their existing scenario rows and
reviews (012/021, 003/022, 006/customer).

## Final review

No production change, new architectural decision, contract change or
dependency change. The independent literal matrix, refusal inventory
equality, one-withdrawal closure, closed-token permanence, cross-peer
schedules and committed-fixture restoration preserve the reviewed access,
ingress and terminal contracts. Remaining gaps recorded on the `sharing`
scenario row: a single native journey driving all three entries in one VM
lifetime, team-role matrix cells and physical-failure renewal timing.

The complete Marshall test execution with `mix test --include distributed
--warnings-as-errors` on the pre-correction tree passed 1,192 checks (141
properties, 1,051 tests), two exclusions, seed `466058`, in 835.2 seconds;
the corrected tree's final gates below supersede that intermediate record.

On the corrected tree the full Marshall `mix precommit` passed end to end:
1,192 checks (141 properties, 1,051 tests), two exclusions, seed `200729`,
forced Dialyzer with zero errors, skips or unnecessary skips, plus the
toolchain, ADR, HLDD, contracts, logging, format, terminal, dashboard and
workspace checks. All-file prek passed its hooks, the generated
options/coverage/views checks are current, and every affected HLDD receipt
group was re-recorded after its reviewed change.
