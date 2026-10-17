# Team resource and distributed retirement verification

## Scope and plan

Campaign improvement 012 starts from published `6f58ef65`. It covers current
team resource authority and actual account retirement overlapping membership and
ownership transfer. ADR-0077 and ADR-0066 remain accepted and partial; ADR-0123
carries forward the current account authentication boundary. The planned tests
preserve their authority and transactional decisions. No production deployment,
provider service or independent physical host is in scope.

Before implementation, source review found that the existing Teams concurrency
test uses independent PostgreSQL connections but substitutes a small retirement
helper for `Accounts.delete_user`. Existing Galileo tests demonstrate a team
owner's integration access but do not generate membership revocation histories.
The previously recorded native Teams tests establish team metadata operations,
not native shared VM or integration use.

## Oracles selected before implementation

- Four deterministic committed schedules invoke the real public account deletion
  action and actual membership/acceptance actions on three independent Marshall
  BEAMs. Target-specific SQL triggers pause real writes without taking production
  account or team locks on their behalf. The competing operation must wait on the
  account advisory fence, not merely an incidental team row lock. The third peer
  must observe only committed authority while the first operation is paused.
- Membership admission before retirement is subsequently archived. Admission after
  retirement refuses. Acceptance before retirement produces one owner and refuses
  retirement of that owner; retirement first cancels pending acceptance. Account,
  memberships, transfers, audit and deletion receipts must agree, including safe
  retirement replay and cleanup completion for an account with no owned VMs.
- Generated real-action resource histories independently model owner/admin/member/
  removed authority. VM read/manage and integration configuration/authorization
  must track current membership; Customer isolation must continue to refuse team
  authority. Refusals must preserve durable intent and resource/audit rows.
- A native fleet journey uses ordinary accounts and packaged Porsche commands for
  team/resource mutations, actual Audi guest SSH for member use, and the actual
  guest private HTTP path to a local TLS Galileo origin. Foreign and removed users
  must lose access; member management must refuse; admins must manage the shared
  VM. Customer resources remain private. Successful and denied integration calls
  are correlated with the local origin counter. Each isolated denied request also
  requires exactly one fresh `galileo.authorization_denied` event with reason
  `unauthorized` across the three Marshall journals; a proxy error alone cannot
  pass as proof of authorization refusal. Renewal is outside these histories.

Native SSH refusals require recognized-key guidance, a fresh Audi catalogue
event with closed reason `unauthorized`, and unchanged ingress/guest-login
receipts. An arbitrary SSH exit cannot satisfy that oracle. Existing open SSH
session termination is outside this check. A bounded SSHAPI regression checks
the exact `forbidden` categories used by the native VM and integration commands.

## Findings and repair

ADR-0077 explicitly admits member use of team machines. The prior Cedar policy
and its mirrored matrix property admitted only `read`. The actual SSH roster,
Audi SSH admission and personal terminal path all require `write`, so the existing
property could pass while members could not use a shared guest. The new generated
history failed at the actual `GuestAccess.roster` result: the current OSS member's
username was absent. This is a violation of the accepted decision. The correction
admits `read` and `write` for current team members while retaining `manage` for
team owners/admins. No schema, wire format or domain boundary changes.

The write-consumer review inspected the production matches under SSH, Ingress,
Terminal, Agents and Compute. Newly admitted use includes SSH roster/key/session
checks, personal terminal creation and input, own-terminal share/kill, and the
existing agent prompt/CLI/tool path with its narrow prompt-triggered wake.
Session ownership and execution fencing remain required. Ordinary lifecycle,
per-machine sharing, resize, clone and relocation still require `manage`;
team-machine provisioning and integration configuration still require team
management. Customer owner-only access precedes Cedar, and Customer's agent and
private-service restrictions remain unchanged. Native terminal/agent acceptance
is tracked by their separate scenarios.

Source and emitted-log review found a second defect before the next native run:
`Galileo.Authorizations` emits its catalogue refusal after the transaction, but
`Marshall.Mailer.LogFilter` discarded `reason` on the authenticated HTTP path.
That violated the existing refusal observability contract and prevented the
required native journal oracle from distinguishing an authorization decision.
The correction preserves only `unauthorized`, `invalid_request`,
`peer_unreachable` and `authorization_invalid` for the exact
`galileo.authorization_denied` event. These atoms are traced from its producers.
It keeps the fixed redacted message, drops arbitrary values and retains mail-tag
precedence when both tags are present. ADR-0042 remains accepted and partial;
no broader diagnostic permission or catalogue metadata key is introduced.

## Execution

The four full-retirement schedules passed with real public actions across three
independent Marshall BEAMs. The first bounded run took 8.7 seconds, seed `195062`;
its constant test-generation warnings were then removed by a typed helper.
A rerun passed all four without those warnings. The test coordinator is excluded
from the peer count. Both committed orders retain account, membership, transfer,
audit and cleanup provenance.

Before the policy repair, focused run seed `460362` completed in 14.6 seconds:
four distributed schedules and the integration history passed; the resource
history failed at the intended missing-member SSH roster assertion. Earlier
fixture attempts corrected per-sample host selection, current report epochs and
sequences, history-action selection and origin-only integration targets before
this product regression was established.

An isolated mutation removed only the production shared account admission fence.
All four deterministic schedules failed at the explicit account-fence wait oracle
in 16.8 seconds. In particular, acceptance's team row lock could not satisfy this
oracle. The mutation was restored; bounded cleanup drained actual actions before
fixture deletion. No mutant is part of the committed change.

The original native derivation
`/nix/store/1sgq0lch6jgv4jgwmw08dzvd9k7zb2wq-vm-test-run-kittens-team-resources.drv`
was captured with the old policy but never executed. Its driver build rejected
an insufficiently narrowed browser dictionary under the pinned Nix `ty`; the
browser now copies validated string keys into `dict[str, object]` before lookup.
A separate pre-fix native run would not add a distinct diagnostic beyond the
real roster regression. Corrected native execution was pending at that point;
the final result is recorded below.

The corrected focused run passed **6 checks (2 properties, 4 tests)** in 28.3
seconds, seed `43402`, with warnings treated as errors.

Before native execution, all 25 distinct SQL observation shapes were extracted
from the driver and successfully prepared and explained in a read-only transaction
against the migrated isolated test database. A synthetic catalogue sample verified
the journal parser's closed-reason projection with unrelated non-JSON lines.
The first executed composed driver
`/nix/store/c39vak1a8yli1qp81wm7iq39016163iz-nixos-test-driver-kittens-team-resources.drv`
passed strict Nix typing and lint with both strengthened refusal oracles. Its
browser helper passed the separate pinned type gate. The corresponding native
candidate was
`/nix/store/9c2z99ahvn2ljwn7wq654p7hbni5zr9n-vm-test-run-kittens-team-resources.drv`;
it passed fleet boot, enrollment and ordinary browser key registration, then
failed with fixture `KeyError: stranger_email` while comparing the third successful
Porsche `whoami` response. All nine machines were cleaned up in 3.60 seconds.
No shared VM or integration acceptance was reached. The public fixture projection
now includes every account's email, and a typed decoder validates all three UUIDs
and emails before browser/VM work. Default-OSS, resize and legacy fleet consumers
read named fields and permit this additive field; no token enters the public
projection. Corrected native execution was still pending at that point.

Marshall's full `mix precommit` passed: **1,047 checks (101 properties, 946 tests)**,
two excluded, in 441.8 seconds with seed `559749`; frontend checks and forced
Dialyzer also passed. Dialyzer reported zero errors, zero skipped findings and
zero unnecessary skips. The later bounded SSHAPI refusal preflight passed one
test in 0.7 seconds, seed `355714`, checking every exact `forbidden` response used
by the native commands. All-file prek, Ruff formatting/lint, Python typing,
contracts, ADR checks, HLDD reference/view checks and the Nix `hldd` gate passed;
final evidence updates will rerun affected documentation gates. After the full
suite, the isolated database contained no retirement fixture teams, triggers or
gate functions.

The branch then integrated published `7681806b` (improvement 009, implementation
`b39ad5f3`). Shared fixture resolution preserves both scenario flags, independently
typed browsers and drivers, operator dispatches and all account-retirement evidence.
That change contains no production logic edit. Its added operator module loads
definitions only; existing team operations keep their behavior. Combined gates
passed after this integration: Marshall's full `mix precommit` passed **1,049
checks (102 properties, 947 tests)**, two excluded, in 495.4 seconds, seed
`931800`. Both generated resource histories and all four full-retirement schedules
passed in this combined run. Frontend checks and forced Dialyzer passed; Dialyzer
reported zero errors, zero skipped findings and zero unnecessary skips.

The second native candidate was
`/nix/store/pcfqbvwb2jpzwll1cr9rjkcz2amhzc6x-vm-test-run-kittens-team-resources.drv`.
Its composed driver
`/nix/store/f52hsb1979wd92xmr0vzz8l1zqjnppy2-nixos-test-driver-kittens-team-resources.drv`
passed strict typing and lint with the early account decoder and complete public
projection. All-file prek and the Nix `hldd` gate passed on the combined tree.
This run passed boot in 64.07 seconds, enrollment/private services in 184.93
seconds, and all three browser registrations and Porsche identities in 30.40
seconds. Team creation and member admission passed. The first shared VM creation
then received HTTP 409 and Porsche's closed `conflict` category. This fixture
has no configured default image, but the command omitted its registered image.
All nine owned machines were cleaned up in 3.58 seconds; no shared guest or
integration acceptance was reached.

The driver now validates the fixture's canonical image digest and names it in
all three real Porsche creates. Bounded diagnostics expose only an allowlisted
failure category. The expanded SSHAPI preflight reproduced the omitted image's
exact `image_unavailable` response, then passed all three exact explicit-image
creation requests and authority refusals in 0.8 seconds, seed `592090`. It checks
persisted owner, team, profile, image and requested sizes. Its three synthetic
hosts retain pending portable-bundle holds; it does not fabricate completed
guests. The response is correctly asserted as `accepted` before physical work.
The earlier full suite precedes this preflight expansion; the final full gate
below includes it. Explicit-image native execution was pending at that point.

Before the filter correction, seed `737994` failed both the generated reason
projection and the actual HTTP refusal capture at the missing `unauthorized`
reason in 0.8 seconds. After correction, **6 checks (4 properties, 2 tests)**
passed in 0.7 seconds, seed `129100`. Negative cases cover arbitrary binary,
tuple, map, unknown atom, string-shaped reason, unrelated event and simultaneous
mail tag. The HTTP check confirms a real 403 refusal retains its closed reason
without its credential. The image-only native candidate
`/nix/store/0k7kbkas5bfnpj9wp1hccp76qrfij537-vm-test-run-kittens-team-resources.drv`
was never executed; its driver build was stopped after this concrete finding.
The in-flight full gate with seed `519229` was interrupted before the filter edit
and is not passing evidence.

The next full run, seed `417791`, encountered 21 VMs and 21 reservations committed
at 17:15:38–17:15:39 UTC during that interruption. This caused 47 failures in
tests expecting an empty database; it is not a passing gate. After the process
exited, the audit confirmed no active sessions used the exclusively owned
`marshall_testverify012` database and no retirement gates remained. Only that
disposable database was recreated and migrated; the source stayed unchanged.

The clean `7681806b`-based `mix precommit` passed **1,051 checks (103 properties, 948 tests)**,
two excluded, in 444.1 seconds, seed `725262`. Frontend checks and forced Dialyzer
passed, with zero errors, zero skipped findings and zero unnecessary skips
(59.12 seconds). After completion, the database contained zero VMs, reservations,
retirement fixture teams, target triggers and gate functions, with no active
sessions. All-file prek, ADR/contract and generated HLDD checks passed; the final
Nix `hldd` gate also passed.

The complete old-base native candidate was
`/nix/store/2wvl1vmnfl1ci05xmgqmra7baldakyja-vm-test-run-kittens-team-resources.drv`.
Its composed driver
`/nix/store/mryyhslpcr37b6ffljq4qqcdr4r6mcas-nixos-test-driver-kittens-team-resources.drv`
passed strict typing and lint. Execution failed at retained-home SSH immediately
after member-admin stop/start. Boot (52.03 seconds), authenticated admission setup
(100.22 seconds), browser/Porsche identity (20.10 seconds), three real guest
creations (110.63 seconds), and shared member use plus foreign/Customer refusal
(10.30 seconds) passed. The subsequent subtest also passed the initial team
integration's HTTP 200, origin increment and body, member/stranger CLI integration
refusals, promotion, stop and start. Removal/re-addition was not reached.

The restart recorded guest trust at 17:47:34.333 UTC and running at 17:47:34.366.
The new connection received an ingress admission at 17:47:35.158, then Audi
reported `connector_failed` at 17:47:35.167. This was a transport failure, not a
successful refusal oracle. Cleanup took 3.62 seconds; the driver and all nine
saved QEMU process IDs were absent afterward. That complete native attempt failed.

Source tracing explains the fixture's premature readiness assumption:
`Lilly.VM.Observation.running?/3` establishes VMM identity, confinement and API
state. Ordinary OSS start returns running after boot trust; only resize/clone
and Inception additionally wait for guest readiness there. Guest roster sync
and its timer separately open sshd after the ready marker. The log is consistent
with startup delay; it does not identify the precise failed connector handshake.

## Integration with the published SSH CA decision

The branch now includes published `aaba77ee`, including ADR-0124's implemented
Linux SSH CA policy and gateway startup recovery. Earlier application/native
results above remain scoped to their captured source; they do not verify this
combined candidate. No new architectural decision is introduced.

The native client validates the deployment-bound public HTTPS SSH trust policy
and derives the exact Audi certificate principal from each current HTTPS route
key. Both SSH connections require Ed25519 certificates, and Porsche uses the
management-host principal. Guest console keys no longer establish client trust.
The fixture uses the evaluated 16 GiB storage budget and retains numeric image
minimum assertions for its 512 MiB/4 GiB requests.

Initial boot, restart and re-added roster checks now require bounded actual SSH
success with the expected result. Running state alone cannot satisfy them.
Denied SSH connections remain single attempts with fresh unauthorized evidence
and unchanged login/session receipts. Integration denials retain the exact
single unauthorized journal event, HTTP 503 and unchanged origin counter.
The combined `aaba77ee`-based `mix precommit` passed **1,047 checks (102
properties, 945 tests)**, two excluded, in 392.8 seconds, seed `142699`.
Frontend gates passed. After rebuilding the upstream runtime's analysis cache,
forced Dialyzer passed with zero errors, skipped findings or unnecessary skips
(55.0 seconds for final analysis). The post-run audit found zero VMs,
reservations, retirement fixture teams, triggers and gate functions, and no
active sessions on `marshall_testverify012`.

All-file prek, Ruff formatting/lint, Python typing, structured logging,
ADR/contract checks, generated HLDD coverage/options/views and Nix `hldd` passed.
The complete certified candidate is
`/nix/store/nba1ninxhx92g3l9nls9bx5ibr8nlrla-vm-test-run-kittens-team-resources.drv`.
Its driver
`/nix/store/g37c4m37nn5ian7g40arkjf28140sjsi-nixos-test-driver-kittens-team-resources.drv`
built in 243 seconds and passed strict typing and lint.

The certified native team-resource journey passed in **396.31 seconds** on
2026-09-25 against that captured `aaba77ee`-based candidate. Its output is
`/nix/store/nfmzhl9frwq19b1w9nhxcbb1fn2gklmf-vm-test-run-kittens-team-resources`.
The six subtests passed: fleet boot (50.35 seconds), authenticated admission
(114.95 seconds), ordinary browser keys/Porsche identity (21.33 seconds), shared,
personal and Customer provisioning (150.96 seconds), member use and refusals
(10.89 seconds), and integration/membership transitions (47.55 seconds).

The actual assertions establish ordinary member home writes, owner and member
shared-guest use, foreign-user refusal, member management refusal, and Customer
member/admin refusal with Customer-owner success. Promoting the member admits
shared-VM stop/start; the subsequent certified SSH connection reads retained home
data. Removing membership refuses new shared-guest SSH and private integration
requests from the member's personal VM. Re-adding membership restores both paths
and the retained home. Ordinary-account checks hold through the journey, all
three guests remain running, and no explicit integration attachments are created.

Refused SSH calls preserve ingress/guest-login counts and require recognized-key
guidance plus a fresh Audi `unauthorized` control response. The isolated denied
integration request returns HTTP 503, leaves the real TLS origin counter unchanged
and yields exactly one fresh Marshall `galileo.authorization_denied` event with
reason `unauthorized` across the three journals. Positive HTTP 200, response body
and origin-counter controls pass before and after membership transitions.

Cleanup completed in **3.52 seconds**. The coordinator confirmed the driver and
all nine captured QEMU processes were absent after exit. Final evidence edits
follow this captured source and introduce no application or native-driver behavior.

## Final integration review

Published `df5f2a3f` was integrated after execution. Improvement 011's
`guestTrust` selector and unconditional private-service prerequisites are
preserved; this journey already selected `audi = true` and the corresponding
trust-enabled image and services. Improvement 015's `defaultOssBrowser` typed
artifact, invocation and exported attribute are preserved alongside the new
`teamResources` selector, strict driver and evaluated storage budget.
These fixture and documentation changes introduce no application change or
new native behavior in the tested team journey. The full application and native
results retain their captured `aaba77ee`-based scope. Final static, contract,
generated-documentation and Nix checks validate the integration separately.

Final integration checks passed on 2026-09-25: ADR structure and links (122
decisions), current HLDD receipts/references, generated coverage/options/views,
repository contract format and coverage, Marshall's `mix contracts.check`
(19 checker regressions), all-file prek (all application logging checks, Ruff
format/lint and ty), Nix `hldd`, and `git diff --check`. Contract discovery
listed the changed Elixir, Nix and Python notes. Cedar syntax is outside the
listing tool's supported languages; its policy, schema, ancestor contracts and
write consumers were reviewed manually as described above. No contract violation
was found in the reviewed scope; structural checks do not establish semantics.

Nix evaluation resolved both the team and guest-trust checks and preserved the
same exported `defaultOssBrowser` artifact as the default-OSS check. The integrated
team driver is
`/nix/store/wdxgribjlgsisd423lx58wp5qrr6982q-nixos-test-driver-kittens-team-resources.drv`.
Its derivation retains `ty check testScriptWithTypes`; its complete `testScript`
is byte-for-byte identical to the previously built and executed `g37c4m37` driver.
The integrated native derivation
`/nix/store/2pfdph7rqd4gx2qgbmmx3glsfn9iinbq-vm-test-run-kittens-team-resources.drv`
was evaluated but not executed. No new native result is inferred from evaluation.

The final architecture review retains ADR-0077's accepted partial status,
ADR-0066's retirement boundary, ADR-0042's closed diagnostic metadata and
ADR-0124's certificate authority. The two production corrections restore these
existing decisions. No schema, protocol, domain ownership or deployment authority
changes; native guest use does not establish the separate terminal/agent paths.

## Remaining boundaries

Independent physical hosts, production rollout and real provider traffic remain
outside this isolated fixture. Full Teams product acceptance remains partial.
Native integration setup invokes the existing Ash action as the ordinary team
owner through the private fixture; positive public CLI integration configuration
is outside this journey. Its public CLI integration refusals and real guest
private HTTP path remain separate assertions.
