# Terminal workspace verification campaign

Date: 2026-09-25. Improvement 013 starts at published `7681806b` and integrates
the unified SSH host CA at `0cfa6302`, then boot trust and gateway startup
recovery through `8773b1b4` and standalone browser typing at `df5f2a3f`,
then team-resource verification at `daa8491d`, before current-source acceptance.

Both complete integrated guest journeys now pass; see final acceptance below.
Earlier sections preserve the observations and outstanding gates at each
historical stage, including failed experiments.

## Plan and architecture impact

Inspect the real browser/guest graphics failure before selecting a fix. Preserve
ADR-0082/0083/0084/0110/0117 transport, personal identity, single writer, sharing,
revocation and five-second host freshness contracts. The allowed path requires
current browser login, Cedar authority, current boot/session and personal guest
account; copied, revoked, foreign and stale authority must refuse. Recovery must
retain the guest shell and its data without replaying input.

1. Correlate browser responsiveness, resource use, output progress and host
   freshness through bounded metadata, never terminal bytes or credentials.
2. Reproduce any defect with a meaningful regression/property; implement the
   smallest correction consistent with accepted contracts.
3. Run both existing native terminal fleets without removing the fifty-shell,
   10,000-image (310,000-byte), visible completion, reconnect, sharing, writer
   or revocation assertions. Run all applicable application/governance gates.
4. Reconcile ADR/HLDD evidence against actual immutable tested artifacts.

## Baseline observations

The predecessor review records incomplete current personal-workspace acceptance.
Its local `small-frames` and `context-loss` probes actually construct fifty panes.
They are synthetic renderer evidence; they do not establish the real transport.
The former completed locally in approximately 3.4 seconds and in a client-only
NixOS VM in 16.5 seconds. One context-loss sample had an internal-buffer marker
but no accessibility marker; a later sample had both.

The separate native DOM-renderer experiment
`/nix/store/53cvbpp0lxmha0ijbmqaddxcba6a8jbz-vm-test-run-kittens-terminal-fleet.drv`
also failed at graphics after passing fifty shells. It received 145,595 bytes,
no completion marker, and bounded DOM reads failed. WebGL-specific failure is
therefore not established. The prior authority-sampling run reported host age
over five seconds and later invalid reports, with unchanged owner/session/intent;
causal order remains unresolved. Collector timestamps precede its mandatory
one-second ZFS interval; no check will restamp stale samples or relax freshness.

## Confirmed delayed-ticket defect

`TerminalWorkspace.mounted` previously attached any known pane when its ticket
reply arrived. A user could select another pane after requesting that ticket;
the late reply then reopened the hidden pane. This violated the existing single
active attachment contract and created an unseen viewer. It has not been
established as the graphics failure's cause.

The delivery boundary now requires the current selection and connected LiveView.
It always removes the old retry timer, allowing a later selection to request new
authority. Ticket consumption, server authorization, replay cursors and guest
session lifetime do not change. This repairs ADR-0084/0117 implementation without
changing their accepted decisions. The small delivery helper is included in the
existing strict TypeScript workspace gate; the surrounding legacy terminal file
and its older unit fixtures remain outside that type-check scope.

The native browser journey now checks each settled command's selected pane owns
an open socket and no other pane owns an open or connecting socket. Closing and
closed sockets are excluded; overlapping close acknowledgements do not represent
live attachments. The observation returns only a boolean and count. Initial
native attachment checks passed on the pre-CA fixture; the full journey remains
pending. The standalone Playwright helper
now passes `ty` against its actual Python/Playwright environment and is gated in
its Nix package; this does not type-check the legacy composed machine driver.
The package's ty 0.0.38 rejected the initial object indexing accepted by devenv's
ty 0.0.73. Rebuilding a dictionary with validated string keys passes both versions;
the earlier explicit-path invocation did check the helper.

## Verification

- Baseline mounted-hook tests: 20 passed, two intentionally failed by attaching
  the inactive/no-selection pane. The selected positive control passed.
- After correction, all 24 terminal JavaScript tests passed. The four ticket
  delivery cases cover selected, inactive, no selection and disconnected state;
  each verifies retry-timer removal. Nine malformed external reply shapes preserve
  pending requests without attachment. Strict workspace TypeScript passed.
- Local current-CSS/ResizeObserver synthetic fifty-pane rendering passed in
  3.23 seconds; a seeded variable-frame partition passed in 4.44 seconds. Both
  internal buffer and accessibility completion markers were present. These
  fixtures use synthetic output and establish no native transport claim.
- Diagnostic native baseline failed graphics after personal identity, home,
  passwordless sudo, account restoration, geometry, clipboard and fifty shells:
  `/nix/store/3vw0syjaby2qwl3519h3mncgd5frcbs4-vm-test-run-kittens-terminal-fleet.drv`.
  It retains pre-fix published source `7681806b` and unchanged native acceptance,
  adding phase timestamps, browser cgroup metrics and host/session metadata.
  The driver lint passed; the legacy composed terminal driver skips type checking.
  Temporary expression SHA-256:
  `2d69e005411074e4e7b406ccc94e265c2b0a79928bb8eb5d2c9f34335dca307c`.
  The graphics command began at VM monotonic 445.929 seconds. It received
  157,094 bytes without completion; bounded DOM reads failed, with no socket
  close or browser-error event. All 315 authority samples remained fresh
  (1.180–3.814 seconds), with unchanged session owner, placement and intent.
  Browser peak memory was 1,264,390,144 bytes. Another native driver and
  build/test processes were active on the host; this does not establish their
  effect. Nine machines cleaned up in 4.31 seconds. The next bounded diagnostic
  collects CPU function/source/timing metadata around graphics, with no terminal
  bytes, network payloads or credentials.

- The corrected pre-CA profiling candidate
  `/nix/store/srm22am9rw0vm8dli76qlima2q7dfzfb-vm-test-run-kittens-terminal-fleet.drv`
  used source tree `38fd9c425182fb172f1c9a360bc7ec020ac36369`.
  Identity/home and passwordless-sudo attachment assertions passed. Account
  removal then lost its connection before completion; DOM reads still worked,
  with 1,207 received bytes and one close. `terminal.viewer_refused` reported
  `authority_host` at 17:53:57.068 UTC. Adjacent samples measured 4.282 seconds
  at 17:53:56.316 and 2.720 seconds at 17:53:57.755. This is consistent with a
  freshness lapse between samples; the threshold crossing was not sampled.
  Ownership, binding and intent remained unchanged. Two other small native
  drivers were active. Graphics and CPU profiling were not reached. All nine
  machines cleaned in 3.03 seconds. This run is diagnostic evidence for the
  older base and establishes no current-source acceptance.

## Native CPU profile on the unified CA base

The frozen candidate based on `0cfa6302`, staged tree
`23f1def992ca159a628d2559d2198a5e7dcfd5bf`, ran as
`/nix/store/wbgp8pav8j4cy89wpwh7b5wl2yh9hb0m-vm-test-run-kittens-terminal-fleet.drv`.
Personal identity/home, sudo, missing-account restoration, title/search/geometry,
clipboard and fifty persistent shells passed, including active attachment checks.
Graphics began at VM monotonic 393.146 seconds and failed visible completion.
The browser received 216,419 bytes with no completion marker or socket close;
bounded DOM reads stopped responding. All 321 non-null host-age samples remained
fresh (1.169–3.330 seconds), with unchanged ownership and execution binding.
There were 330 samples including nine before a session existed. Browser peak
memory was 1,327,366,144 bytes. Nine machines cleaned up in 3.70 seconds.
Concurrent host builds were observed; their causal effect is not established.

A sanitized CPU profile contains 29,840 samples spanning 157,747.928 ms.
`getBoundingClientRect` accounts for 137,389.565 ms of self time. The inclusive
path is sixel image `unhook` → `addImage` → scroll/line feed → accessibility
`_refreshRows` → `_renderRows` → `_alignRowWidth`. The shipped asset is
`app-03930d7234b72aff0142c6562cb95b38.js` in
`/nix/store/j1zvwamxynwkzrkw9v3j00bahhlz82rs-kittens-marshall-0.1.0`.
Inspection of the pinned xterm 6.0.0 source confirms that row text/style writes
alternate with forced geometry reads. Its accessibility debouncer records time
before the synchronous refresh: a refresh lasting at least one second can let
every following scroll trigger another immediate refresh. This establishes the
observed layout bottleneck; a passing corrected native run is still required.
Screen reader output and visible completion remain required acceptance oracles.

## Accessibility layout correction

The original vendor code failed three regressions against its actual
`AccessibilityManager` methods: a full refresh forced three modeled layout flushes,
a partial refresh forced two, and resize forced three; each expected one. Mixed
ASCII, CJK, combining and blank text, logical columns, ARIA positions and row scales
already passed. After batching text/height/transform writes, measuring natural row
widths together, then applying scales, all three regressions passed. The shipped
artifact integrity regression also passes. All 28 terminal JavaScript tests pass.
These model DOM invalidation and preserve exact scales; native Chromium is the
performance and accessibility acceptance boundary.

The patch covers both callers (`_renderRows` and `_refreshRowsDimensions`). Boundary
focus continues to rotate DOM rows and request scrolling; selection still uses the
unchanged logical-column map and ARIA positions. Refresh scheduling, cancellation,
live-region announcements, input/credit handling and authority are unchanged.
The native journey additionally selects real ASCII/CJK/combining output through
the accessibility DOM and checks xterm's selected text before graphics and after
reconnect. The captured native executions below passed both assertions.

A fifty-pane synthetic Chromium fixture at eightfold CPU throttling failed the
120-second visible completion assertion with unmodified bundled assets, and again
with accessibility CSS containment. A temporary post-refresh debounce timestamp
experiment completed parsing in 101.777 seconds, with 37.827 seconds spent in
4,125 accessibility row measurements. Its 500 ms snapshot preceded the trailing
accessibility update; the final visible marker assertion passed. Neither experiment
is included in the correction. The batch experiment used the patched source module
and the same packaged CSS and workload; it completed in 77.620 seconds, with both
buffer and accessibility markers and 3.171 seconds across 4,917 row measurements.
This is synthetic, throttled evidence, not a native transport result or controlled
fleet performance comparison.

### Vendor provenance and architecture impact

This is an explicit, reviewed exception to the previous prohibition on local
vendor edits, justified by the measured upstream layout defect. Application policy
still belongs in hooks; local upstream corrections now require original and patched
integrity, reproduction instructions, architecture review and executable regression.
The xterm 6.0.0 tarball was downloaded from its recorded official npm URL and its
existing SHA-512 integrity verified. The original ESM differs from the former
vendored file only by removal of the source-map comment. CSS and license remain
byte-for-byte upstream. The patch manifest records original tarball/ESM/source and
patched ESM hashes; the readable TypeScript patch and exact minified replacements
are reviewed together. `scripts/patch_xterm.py` reproduced the exact shipped bytes
from the official tarball, and its artifact check passed. No CDN or new dependency
is introduced. A future upgrade must rerun these regressions and both native fleets.
The coordinator independently reviewed the patch, both width-alignment callers and
resize/focus/selection consumers with no source finding. Zero-width handling remains
unchanged. Strict TypeScript checking passed for the new shipped-artifact regression
using the repository compiler and disposable `@types/node` 24.10.13; older terminal
test fixtures remain outside that type-check scope. The Python reproduction tool
passed development typing and the actual Nix `python-static` check (ty 0.0.38).
The patched upstream TypeScript accessibility source and its transitive imports
also passed strict checking with the official public declarations and VS source
aliases/flags; this is not a rebuild of the full upstream package.

The implementation correction remains within ADR-0084/0117's renderer contract and
ADR-0082/0083's existing transport. It changes no domain, persistence, authorization,
freshness, protocol or native isolation decision. No containment or debounce timing
change is retained. Complete native acceptance and integrated application/governance
gates remain required before completion.

## Integration with ADR-0124

The `0cfa6302` integration preserves the accepted unified SSH host CA, the
16 GiB fleet disk and `storage_budget`, guest certificate bootstrap/readiness,
and the shared Rust/OTP trust implementation. Terminal frontend and workload
code did not change upstream. The selection correction and standalone terminal
browser type gate remain; the new host-certificate authority is not bypassed.
The later `8773b1b4` integration preserves unconditional fleet guest trust
delivery, Audi/Galileo readiness fixtures and bounded gateway certificate startup
retry. The `daa8491d` integration retains team member read/write and owner/admin management
authority, team-resource fixtures and the exact Galileo diagnostic filter. The
terminal viewer-sharing restrictions remain independent. Both complete native
journeys must run against the integrated source.

## Application and governance checks

- On base `0cfa6302` and staged tree `23f1def992ca159a628d2559d2198a5e7dcfd5bf`,
  Marshall `mix precommit` passed 1,038 checks (99 properties and 939 tests), two
  exclusions, seed 792046, 377.8 seconds. All 24 JavaScript terminal tests passed.
  Forced Dialyzer passed with zero errors, skips or unnecessary skips (52.82
  seconds after its PLT addition phase). Contracts, ADR/HLDD/options/coverage/views,
  all-file prek and Nix HLDD passed. The Nix HLDD artifact was
  `/nix/store/1xa61588qa7s007dj5vy0kk69a0qys04-kittens-hldd-check`.
  These checks precede the later `8773b1b4` integration and any graphics fix.

- Marshall `mix precommit` passed: 1,042 checks (100 properties and 942 tests),
  two exclusions, seed 106850, 409.4 seconds. Forced Dialyzer passed with zero
  errors, skips or unnecessary skips (70.99 seconds after PLT relocation/rebuild).
- Strict workspace TypeScript, contracts, ADR/HLDD/options/coverage/views,
  all-file prek and the Nix HLDD check passed, including the additional native
  attachment assertion and both standalone Nix browser type gates. These results
  precede the CA integration; combined gates and complete native journeys remain
  pending.

No production deployment is included in this campaign change.

## Captured native graphics success and recovery failures

On base `daa8491d`, staged tree `75772ebab796d940b00a53ac0ee115937c23dbb5`,
Marshall precommit passed 1,047 checks (102 properties and 945 tests), two
exclusions, seed 680018, in 401.2 seconds. All 28 terminal JavaScript checks
passed. Forced Dialyzer reported zero errors, skips or unnecessary skips in
56.23 seconds after a 22-second PLT update. Governance, all-file prek, Nix
`python-static` and Nix `hldd` also passed on this captured source.

The first corrected native NixOS run was
`/nix/store/9i6hd9fqk0ppcj6kz3jaw93zbyv7s3kc-vm-test-run-kittens-terminal-fleet.drv`.
Its packaged asset was `app-804a1a1a18dddde7b15aec41c4d96ec1.js` in
`/nix/store/9zcq6yynjm8m143rrp5iva8csn70q572-kittens-marshall-0.1.0`, SHA-256
`3d39230a4351b3053c78ce1dbc86fec49358e80211546ec50c4b686d10b68b40`.
The batch method and both callers were checked in that actual release.

Both native mixed-width accessibility selections passed, before graphics and
after reconnect. Fifty persistent shells, the full 10,000-image/310,000-byte
graphics stream, accessible visible completion, reconnect and retained shell
passed. Graphics began at VM monotonic 441.505 seconds; the retained-shell
command began at 460.773 and second selection at 463.567. Initial sharing and
unshared-user refusal also passed before the owner/member observed command at
494.085. The profile has 2,668 samples over 14,182.749 ms; its largest individual
`getBoundingClientRect` self-time node is 242.410 ms. Other layout nodes exist;
this is not an aggregate layout duration or a controlled performance comparison.

The full journey failed later at the existing 35-second lost-node database
connection bound. The explicitly held transaction timed out, followed by ordinary
dead-client transactions at successive 15-second intervals. Four original m1
backends remained, with active lock waiters behind an idle transaction. The
36-second transaction age does not establish 36 seconds in the idle state.
All 230 non-null authority samples before crash were fresh (1.178–3.314 seconds),
with correct ownership and execution binding. Final host ages reached 37 seconds
during the lock convoy. Cleanup took 3.78 seconds; all nine QEMUs were confirmed
absent. The browser log was recovered read-only from its preserved stopped disk
because the coordinator exception preceded its ordinary log collection.

A diagnostic run of the same application tree,
`/nix/store/n0sgyclm51j62j5pjvg26gvm31jv4ddk-vm-test-run-kittens-terminal-fleet.drv`,
retained the original assertions and collected connection state/query ages and
the browser log on failure. This schedule had idle connections, with no sampled
lock waiters, and reclaimed all captured connections after 30.848 seconds.
Graphics, replay, retained shell and both accessibility selections passed again.
The full journey then failed at the 45-second `data-status=live` assertion after
detecting a replacement socket. An initial `authority_host` refusal was followed
by admitted attachments, while later host samples were fresh. A socket replacement
alone therefore did not establish restored terminal usability. All 286 non-null
sampled ages were 1.180–3.237 seconds; the samples omit the coordinator's crash
wait, so they cannot disprove the initial refusal's freshness lapse. Cleanup took
3.53 seconds and all nine QEMUs were confirmed absent.

The added two-machine database-recovery fixture makes the missing schedule
explicit: the real release Repo holds one row lock and three distinct connections
must be observed waiting on that lock chain before its machine is stopped.
It retains the original 20-second holder and 35-second all-connection bounds.
Failure-only observation continues to 75 seconds and still fails the original
assertion. The controlled native results below distinguish the failed baseline,
failed polling-only candidate and passing combined correction.
The browser now reports only closed status/mode values, booleans and bounded
socket/replay counters if the post-crash live assertion fails. It exposes no
terminal bytes, arguments, identities or tickets.

Two preliminary database-fixture attempts failed before Repo startup. The first
temporary baseline expression copied the release directory without its runtime
closure; it now uses `builtins.storePath` to retain the original release. The
second exposed the transient systemd manager's restricted `PATH`. The fixture
now uses pinned coreutils for its directory creation and supplies the same
explicit service `PATH` as the existing fleet operator. These attempts establish
no recovery result. Both two-machine runs fully cleaned up (0.21 and 0.10 seconds).

The baseline release is captured from `daa8491d` plus the staged graphics fix;
the candidate release is captured from `38edcbea` plus that fix and a temporary
one-second disconnect-polling overlay. These are different full source trees.
The fixture starts only the release Repo, its dependencies and a task supervisor.
The exercised Repo bytecode, runtime configuration source before the overlay,
runtime configuration file, release boot files and dependency lock are identical.
The dependency fetch hashes and Cedar output are unchanged. Across 5,544 packaged
runtime/dependency files, differences are the release-root startup path and two
Decimal/Cinder BEAM artifacts with identical abstract code; executable chunks
also differ, so this is not a claim of full binary identity. The candidate's
only intended startup-setting change is `client_connection_check_interval=1s`,
which the native fixture reads back from PostgreSQL alongside every existing GUC.

The corrected baseline fixture
`/nix/store/vlzh77215zr73kd8jb3x19yb00ifcpal-vm-test-run-kittens-database-recovery.drv`
verified the healthy two-second query, effective production parameters, distinct
holder/three queued waiters and ten Repo connections before machine loss. The
holder met its 20-second bound. The all-connection assertion failed at its
unchanged 35-second bound: at 35.183 seconds two captured backends remained,
one idle in a transaction for 7.547 seconds and one still waiting for its lock.
The holder and successive idle waiters expired at database monotonic 34.265,
49.268 and 64.273 seconds. Failure-only observation first found no remaining
connections at 43.050 seconds after client loss; it did not turn the failed
35-second assertion into a pass. Cleanup took 0.12 seconds and both QEMUs were
confirmed absent. This reproduces the lock-convoy gap independently of the UI.

The first candidate,
`/nix/store/hmndpwb4x3dc48xixddbngcv7j5z59ck-vm-test-run-kittens-database-recovery.drv`,
read back one-second disconnect polling and all unchanged production settings.
It passed the healthy query and required lock schedule, but still failed the
35-second reclamation bound. Polling removed an active waiter; another had
already acquired the lock and entered an idle transaction, whose sampled state
age at 35.240 seconds was only 7.555 seconds. The first empty failure-only sample
was at 43.049 seconds. Cleanup took 0.12 seconds and both QEMUs were confirmed
absent. Polling alone is therefore insufficient and was not adopted by itself.

A second temporary candidate keeps one-second polling and reduces the TCP
unacknowledged-network limit to 15 seconds. This changes tolerance of a stalled
network, not SQL execution duration. The helper now explicitly reads back both
settings and its healthy `pg_sleep` control lasts 20 seconds, longer than that
candidate network limit; earlier runs used two seconds. The lock schedule and
20-second holder/35-second connection assertions are unchanged.

The second candidate passed in 68.07 seconds:
`/nix/store/53mi80rgxpwnxd86rs02ky0ic4m7ma11-vm-test-run-kittens-database-recovery.drv`.
Its release was `/nix/store/g5nw67wgxng6ch3hm00pyphx39da0w3y-kittens-marshall-0.1.0`,
built from the same stored source as the polling-only candidate with only the
additional TCP setting change. The actual helper SHA-256 was
`5b33ba9054b6eab1a96ceeb19039d5d0e502feb9ec0ebab72654b0cc6510c8ab`.
Healthy 20-second SQL, exact setting readbacks and the observed lock schedule
passed. The holder met 20 seconds; all ten captured backends disappeared in
27.719 seconds, and another connection acquired the row. Cleanup took 0.12 seconds;
both QEMUs were independently confirmed absent. Standalone Dialyzer of the helper
module with the unchanged Repo passed without findings in 0.74 seconds. That
check caught `Logger.configure(level: :none)` outside its declared contract;
the helper uses the typed Erlang primary-logger setting for global suppression.

Architecture review accepted the combined correction under
[ADR-0126](../decisions/0126-bounded-database-client-recovery.md). It replaces only
the inherited database setting through ADR-0053, preserving unrelated decisions
and rationale. Runtime configuration and its complete-setting regression now
use both values; no statement timeout, uncertain-input replay or authority
relaxation is introduced. The shorter network tolerance and the need to reconnect
existing database sessions are documented. This candidate evidence does not
resolve the separate post-crash browser usability failure.

After adopting the correction on main `7f7ee2cb`, the focused runtime suite passed
12 checks (3 properties and 9 tests), seed 226258, in 0.2 seconds. All 28 JavaScript
terminal tests passed. Strict workspace TypeScript, shipped vendor integrity,
Python formatting/lint, ADR structure, code contracts and generated handbook
options/views/coverage checks passed. These are preparation checks; the integrated
full precommit and complete terminal machine journeys were still required at
that stage; their final results are recorded below.

The later main integration at `38edcbea` preserves improvements 014 and 016:
SSH registration/account-retirement admission and captured integration-renewal
and peer-token evidence. It changes no accepted terminal authority decision.
Integration through `7f7ee2cb` also preserves improvement 017's mirror fencing
and improvement 018/ADR-0125's immutable fresh guest identities. The terminal
ledger retains the separately passing account-lifecycle identity journey; that
journey does not establish this full graphics and machine-loss sequence. The
browser coordinator now collects the existing allowlisted public helper log in
`finally`, including when a coordinator assertion fails before ordinary collection.
Integration at `3f679eff` preserves improvement 019's complete administrative
job-attempt history and its generated/native evidence. It changes no terminal
authority or database startup contract. Final capture follows that integration.

## Final integrated acceptance

The executable candidate was frozen on main `3f679eff7601491e199152a316d9ad59e5c87938`,
staged tree `e710ef1e2de6e83a52bfa3ccdc40edf745f9ed27`. Both complete terminal
journeys passed on that unchanged candidate. Subsequent edits record evidence
and review receipts; they do not change the exercised executable sources.

| Guest | Exact test derivation | VM-script context | Driver summary | Browser journey | Cleanup |
| --- | --- | --- | --- | --- | --- |
| NixOS | `/nix/store/z9qyy2a1hdlwh56rj5ak54n0nxapc3g6-vm-test-run-kittens-terminal-fleet.drv` | 702.42 s | 702.66 s | 462.50 s | 3.59 s |
| Ubuntu | `/nix/store/pij9l2xf6g2vcg4k5l7qx3gbpcaqmn08-vm-test-run-kittens-terminal-ubuntu-fleet.drv` | 683.84 s | 684.10 s | 379.78 s | 4.76 s |

The VM-script context is the driver's `finished: run the VM test script` timer;
the slightly longer summary is its separate `test script finished` timer.
Neither includes the separately recorded cleanup timer. These are execution
durations, not a controlled guest-performance comparison. Both owned sessions
exited zero. All nine machines, the restored Marshall replacement and both
drivers were confirmed absent, with an independent cleanup review before the
next native run. No production resource was used.

Both used release
`/nix/store/bg8gyn0ach9gi478bgipjkgdlqg3dx17-kittens-marshall-0.1.0` and browser
helper `/nix/store/smzq6vwrr97p0z9ld6fwdr4d49aqwcxh-terminal-browser-typed/browser.py`.
The helper SHA-256 `383f2abcd628a2b2287f8bfff61f8bd5c6e0feb4ac27b99edb47c2ee1a61d4c7`
matches the reviewed source. No synthetic terminal replies, weakened deadlines
or fixture-specific production timeout override were used.

Both complete terminal journeys passed personal identity/home, passwordless sudo,
missing-account restoration, title/search/geometry/clipboard, fifty persistent
shells, all 10,000 sixel images (310,000 bytes), and accessible completion within
120 seconds. Both native mixed-width selections passed before graphics and after
replay. Settled attachments remained selected-only. The real shell and its effect
survived reconnect and whole-Marshall machine loss; the existing 20-second holder,
35-second connection reclamation and 45-second restored-live assertions passed.
Sharing, foreign-user refusal, operator view-only input refusal, grant revocation
and login revocation all passed. The earlier post-crash status failure remains
historical evidence; these passes do not isolate its cause from the changed
database timing and the wider schedule.

The frozen candidate's complete Marshall precommit passed **1,092 checks
(111 properties, 981 tests)**, with two exclusions, seed 498122, in 447.8 seconds.
Forced Dialyzer reported zero findings in 65.24 seconds. All 28 terminal
JavaScript tests, strict workspace TypeScript, vendor artifact integrity,
all-file prek, Nix `hldd` and `python-static`, ADR/contracts and generated handbook
coverage/options/views checks passed. The newer browser helper has its actual
Playwright type gate; the legacy composed terminal driver still skips typing.

After the evidence-only handbook updates, all-file prek, Nix `hldd`, the reviewed
receipts and generated-reference checks passed again. The focused handbook/live
page and HLDD validator suites passed 28 checks (7 properties, 21 tests), seed
194446, in 5.8 seconds. The diff from the frozen candidate contains only `docs/`
and `marshall/priv/hldd/` evidence changes.

### Recovery capture equivalence

The passing `53mi80rg` database fixture retains its original captured source scope;
it is not relabeled as a new integrated execution. Its driver bytes after the two
evaluated constants match the current driver, with values 1000/15000 matching the
adopted defaults. The helper differs only in reviewed comments; parsed executable
ASTs match. The current RuntimeConfig AST matches the exact captured source with
the two reviewed overlays. Its packaged BEAM differs only in the `Line` chunk;
executable chunks match. The actual Repo BEAM is identical, SHA-256
`dd1a6f79270eff991e1120e03a74b5f63dda05b35aa0d9682a975aebf92337bf`.
Runtime startup source, dependency lock and TLS database fixture are unchanged.

Across the captured and integrated releases, 5,594 non-application files match.
Two wrappers differ only in their release path. The other difference is
`Cinder.Collection`: its abstract code matches but executable chunks differ.
This establishes the inspected recovery inputs, not full release binary identity.
Repeating the deterministic convoy solely for provenance is unnecessary; the
full integrated terminal tests separately establish adopted browser recovery.

### Final architecture and contract review

ADR-0126 is implemented for its recorded native scope and narrowly replaces the
database recovery settings inherited through ADR-0053/0030. ADR-0084/0117 retain
their terminal decisions; ticket selection and the measured vendor correction
repair implementation. The reproducible vendor exception preserves provenance,
artifact hashes, license and actual shipped-method regressions. Review found no
new contract violation in the changed source or its consumers.

Ash ownership, wire formats, execution fences, five-second freshness, input
non-replay, stream credits, guest isolation and native storage ownership remain
unchanged. Domain and deployment views require no inventory change. Existing
guest-disk upgrades, physical/provider failure behavior, production network/load
tolerance and assistive-technology integration beyond the tested accessible DOM
remain outside this evidence. Generated reconnect/writer-epoch histories remain
a future coverage improvement. Existing serving connections require ordinary
reconnection to adopt the new startup settings; no rollout was performed.
