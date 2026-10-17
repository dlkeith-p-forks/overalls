# Default guest Starship review (2026-10-10)

## Scope and authority

The user authorized stock Starship prompts for every interactive user in rebuilt
NixOS and Ubuntu Firecracker guest images, implementation in a new worktree,
verification, commit, merge to main and push. This review covers image defaults,
locked Ubuntu inputs, dynamic account shell reconciliation and native prompt checks.
Production deployment and rewriting existing VM disks are outside that instruction.

[ADR-0150](../decisions/0150-default-guest-starship.md) is an accepted additive
decision. ADR-0068's locked Ubuntu image boundary and ADR-0094's toolset remain
in force. The account and personal-terminal requirements carried through
ADR-0110, ADR-0117 and ADR-0125 remain unchanged.

## Architecture assessment

The prompt belongs to guest shell startup. NixOS uses its pinned Starship module;
Ubuntu uses its signed-snapshot package with one global initializer for login and
non-login interactive Bash. The stock NixOS module skips prompt initialization
when `TERM=dumb`; normal browser and SSH terminals advertise a capable terminal.
Ubuntu's guarded initializer initializes interactive Bash even with `TERM=dumb`.
Neither path writes user dotfiles. The managed reconciler restores a stable
executable Bash path before account activation or refresh, without changing
identity, roster or host transport schemas.

The change introduces no Ash resource, deployment role, persistent control-plane
state, privileged service, listener, credential or authorization action. Current
roster proof, Cedar admission, certified SSH, terminal execution fences and native
storage/isolation ownership retain their existing boundaries. Root interactive
prompt support does not enable remote root login or serial autologin.

A missing Bash fails before account/state mutation. Ubuntu initialization suppresses
prompt output for noninteractive shells, remains idempotent within a shell and
initializes nested Bash independently. Image identity and manifest-derived disk
sizing absorb the added package closure through the existing builder contracts.

No material design conflict was found. Earlier account ADRs govern authority,
identity and homes, but do not prescribe `/bin/sh` as an architectural requirement.
Changing that implementation default does not require supersession. Source review
inspected shell selection, creation/refresh callers, the pinned NixOS module,
Ubuntu's initializer and protected paths, and the actual native fixture changes.
Both Ubuntu locks retain signed snapshot `20260918T000000Z` and native Starship
`1.22.1-9ubuntu1`, offline installation and exact lock/request matching. The
browser authority contract remains attached to its original `run` declaration.

## Verification

The following checks passed in the repository's pinned environment before the
independent-observability integration:

- Full Lyra native check, including Clippy, unit, property and integration tests;
  all 13 `kittens-ssh-authorize` tests passed, including executable Bash selection
  and refusal. These establish local helper logic and Rust typing.
- `guest-toolset`, `ubuntu-guest-unit` and `ubuntu-build-boundaries`, all-files
  `prek` static hooks, ADR/code-contract checks, generated reference and scenario
  checks, Ash/deployment views and the evaluated Nix `hldd` check passed.
- Marshall's full `mix precommit` passed exit 0: 1,249 tests, 254 properties and
  two excluded tests; forced Dialyzer reported zero errors. Its log is
  `/tmp/kittens-starship-marshall-precommit.log`. Application and typing results
  remain separate from the native prompt evidence below.

### Historical native root images

These results were captured at feature `63214e60` on base `1cd8be40`, before integration.

Both complete root machine suites passed stock Bash/Starship startup for root
and ordinary manually created users, nested interactive shells, exact
noninteractive stdout and checked account/home cleanup.

The complete Ubuntu root machine suite passed exit 0 in 2,176 seconds. Its result
is `/nix/store/rl9db7k0bp93w31zaak9z5dbv3wn513k-vm-test-run-kittens-ubuntu-guest`,
with raw log
`/home/ghuntley/.local/state/nix/build-logs/1791591855477-453264-0.jsonl`.
It verified root Bash and active Starship hooks, nested login and non-login
shells, exact noninteractive stdout and a disposable account created by plain
`useradd` without explicit shell or fixture dotfiles. The corrected fixture
requires checked `userdel -f -r` completion and verifies both account and home
absence. Prompt probes recur during real restart, abrupt loss, resize and clone
checks.

The complete NixOS root machine suite passed exit 0 in 4,016 seconds. Its result
is `/nix/store/qa8f3r9zkwpmgf7g52j1yngc1a6qs6yc-vm-test-run-kittens-zfs-guest`,
from derivation
`/nix/store/ckya2kkg7gk4my86a1fqggwrdnk1j5b7-vm-test-run-kittens-zfs-guest.drv`,
with raw log
`/home/ghuntley/.local/state/nix/build-logs/1791591855478-453265-0.jsonl`.
It passed repeated root/manual-account prompt probes through real restart,
source recovery, abrupt loss, capacity, resize and clone scenarios. The full
suite completed its final Inception clone block. This is the corrected fixture
with checked disposable-account cleanup.

### Historical personal SSH and browser terminals

These results were captured before independent-observability integration.

Both serial managed-user journeys passed stock Bash and Starship startup,
including certified SSH, nested login/non-login shells, exact noninteractive
stdout, two successful roster-service refreshes, a real personal HTTPS browser
terminal, relocation and reboot.

The NixOS managed-user journey passed exit 0 in 1,257 seconds. Its result is
`/nix/store/igfx7yzya1c5qwh6l4b02mikvfzzx18a-vm-test-run-kittens-user-ssh-journey-fleet`,
with raw log
`/home/ghuntley/.local/state/nix/build-logs/1791592480622-487161-0.jsonl`.
This execution used the earlier strict direct-refresh fixture, before bounded
retries were added; it does not claim execution of that later harness. The
production guest image and account code were unchanged by the fixture adjustment.

The final pre-integration Ubuntu managed-user journey passed exit 0 in 951 seconds. Its result is
`/nix/store/yj4lprix9nj45xpjc608aw9xjrwhm20n-vm-test-run-kittens-user-ssh-journey-ubuntu-fleet`,
from derivation
`/nix/store/7lmz7fb3i0zpl44a8zy2h9767qwvn4hy-vm-test-run-kittens-user-ssh-journey-ubuntu-fleet.drv`,
with raw log
`/home/ghuntley/.local/state/nix/build-logs/1791594598747-631597-0.jsonl`
and wrapper transcript `/tmp/kittens-starship-ubuntu-journey-rerun.log`.
This execution requires each of two actual roster-service completions within
60 seconds, then repeats the same SSH hook assertion before its focused browser
path, relocation and post-reboot assertion.

The focused browser checks use Chromium with verified HTTPS and real personal
PTYs on the ordinary guest of each distribution. They do not credit broad
sharing/revocation, fifty-terminal or graphics acceptance to this prompt-only path.

### Earlier attempts and fixture corrections

The initial aggregate root run exited 1 at `boot_identity_unconfirmed` adoption.
Its log is
`/home/ghuntley/.local/state/nix/build-logs/1791590588969-197132-0.jsonl`, with
wrapper `/tmp/kittens-starship-native-guests.log`. An unchanged Ubuntu rerun
passed that step, then exposed ignored disposable-account cleanup. The cleanup
failure wrapper is `/tmp/kittens-starship-ubuntu-guest-rerun.log`. Checked
`userdel -f -r` and explicit account/home absence made the final Ubuntu root suite
pass. These observations do not establish a host cause for the original adoption
failure.

The initial parallel native fleet attempt exited 137 under runner memory pressure.
That attempt is not passing evidence; the serial executions retain their own
exact artifacts and scope.

A prior serial Ubuntu managed attempt exited 1 after 468 seconds. Its initial
Starship SSH assertion and first forced roster-service reconciliation passed;
the second `systemctl start kittens-ssh-sync.service` exited 1. The underlying
helper refusal reason was not captured. Database cleanup timeouts do not establish
its cause. Source review confirms that shell and expiry updates do not have the
busy-user restriction applied to UID changes; this is not a runtime diagnosis of
that attempt.

The narrow fixture correction waits for two successful service completions
within 60 seconds each before rechecking the same SSH hooks. It preserves
fail-closed authorization and does not change production code or accept failed
reconciliation as success. Format, lint and contract checks passed for the
adjustment; the final 951-second Ubuntu rerun supplies its native execution.

## Integration with independent observability

The Starship feature was committed as `63214e60` on base `1cd8be40` before
merging independent-observability revision `a2d9e6e`. All four native artifacts
and the component/static gate results above are historical executions from
before that merge; they do not establish the integrated runtime. The NixOS
configuration, Ubuntu builder/initializer and `kittens-ssh-authorize` source are
unchanged across integration, preserving their recorded prompt evidence.

Upstream [ADR-0149](../decisions/0149-independent-observability.md) remains
accepted/partial, with its coordinated Lilly v4/Ziggy v2 cutover, independent
observability ownership and supersession links intact. The additive guest decision
is renumbered ADR-0150 to avoid the independently allocated ID. Its acceptance,
rationale and implemented guest behavior are preserved. The merged overview,
guest chapter and scenario ledger retain both decisions and their separate evidence.

Final source and code-contract review of the staged integrated candidate found
no violations or conflicts in guest startup, signed Ubuntu locks, roster/timer
and terminal callers, or changed native fixtures. Inception inherits the same
NixOS configuration; NixOS preserves its native terminal guard and Ubuntu's
unexported shell guard permits nested hooks. Bash validation precedes account or
state writes; creation and refresh apply the stable executable shell. Terminal
account materialization precedes passwd lookup and privilege drop. Existing UID,
home, sudo, retirement and authorization authority remains unchanged. This source
review does not add runtime acceptance claims.

### Integrated component and static checks

The full Lyra Cargo unit/property/integration and Clippy gate, `guest-toolset`,
`ubuntu-guest-unit` and `ubuntu-build-boundaries` passed exit 0 in a combined
297-second build on the `63214e60`/`a2d9e6e` candidate. The transcript is
`/tmp/kittens-starship-integration-evaluation.log`, with raw log
`/home/ghuntley/.local/state/nix/build-logs/1791596440235-792411-0.jsonl`.
The realized outputs, respectively, are:

- `/nix/store/l8984rj4asqxigs1a4vl3szwzvr64s0q-lyra-tests-0.1.0`
- `/nix/store/dyki2wjk2i2m294k1lmvjgsb2awm5war-guest-toolset-config`
- `/nix/store/ijrlhvrcac0lfiip2m55p46sp2jdklam-ubuntu-guest-unit-properties`
- `/nix/store/skc1ybh9jaqkr4prwl0xy9xbpsikhbbr-ubuntu-build-boundaries`

Integrated all-files `prek` also passed, including Ruff format/lint, `ty`, event
catalog checks, conflict markers and HLDD review. Its transcript is
`/tmp/kittens-starship-integrated-prek.log`. These gates establish local typing,
helper behavior, locked-image wiring and static contracts; native shell execution
has separate evidence below. Marshall's full precommit and the evaluated Nix
handbook pass above retain their pre-integration scope.

### Integrated personal SSH and browser terminals

Both merged managed-user journeys passed stock Bash/Starship startup on the
`63214e60`/`a2d9e6e` candidate, using Lilly v4 control and the integrated fleet.
Each ran serially and required two actual successful roster-service completions
within 60 seconds apiece. Real certified SSH checked passwd Bash, Starship hooks,
nested login/non-login shells and exact noninteractive identity/home stdout.
Focused Chromium terminals used verified HTTPS and ordinary personal PTYs;
Starship hooks survived relocation to the destination and guest reboot.

The merged NixOS journey passed exit 0 with a native driver time of 890.30 seconds.
Its realized output is
`/nix/store/r63sn80d6yn5794nscqz50l6lsf5rm6m-vm-test-run-kittens-user-ssh-journey-fleet`,
from derivation
`/nix/store/5zvb9aw2znsripsxlrq0g0k2k81qzjdw-vm-test-run-kittens-user-ssh-journey-fleet.drv`.
The raw derivation log is
`/nix/var/log/nix/drvs/5z/vb9aw2znsripsxlrq0g0k2k81qzjdw-vm-test-run-kittens-user-ssh-journey-fleet.drv.bz2`;
the transcript is `/tmp/kittens-starship-merged-journey-nixos.log`.
Its SSH/HTTPS Starship group passed in 69.71 seconds, relocation in 199.82 seconds
with destination hooks, and reboot/cloning in 174.33 seconds with post-reboot hooks.

The merged Ubuntu journey passed exit 0 with a native driver time of 909.18 seconds
(the nested VM script reported 908.76 seconds). Its realized output is
`/nix/store/64a106w4jk995xzkv4iz81gqcgih4gaa-vm-test-run-kittens-user-ssh-journey-ubuntu-fleet`,
from derivation
`/nix/store/15nhax96yqclgji7ivxcbf6cw3q9nac6-vm-test-run-kittens-user-ssh-journey-ubuntu-fleet.drv`.
The raw derivation log is
`/nix/var/log/nix/drvs/15/nhax96yqclgji7ivxcbf6cw3q9nac6-vm-test-run-kittens-user-ssh-journey-ubuntu-fleet.drv.bz2`;
the transcript is `/tmp/kittens-starship-merged-journey-ubuntu.log`.
Its SSH/HTTPS Starship group passed in 71.04 seconds, including the Ubuntu package
registry checks; relocation passed in 222.79 seconds with destination hooks, and
reboot/cloning in 217.21 seconds with post-reboot hooks. Both realized outputs were
independently confirmed by `nix path-info`, and both native sessions completed cleanup.

These complete focused managed journeys verify prompt behavior through the merged
control/fleet path. They do not credit broad browser sharing/revocation,
fifty-terminal or graphics acceptance, independent diagnostic-custody recovery,
or production deployment. Root/manual-user suites retain their exact historical
revision scope; no merged root-suite execution is claimed. No pre-integration
artifact is credited as a rerun of the changed control/diagnostic boundary.

## Remaining gaps

Native probes inspect stock startup. Generated shell-change/reconciliation-failure histories and native
rendering of custom per-user Starship configuration remain untested. Scenario
coverage therefore remains partial. The stock NixOS module intentionally skips
`TERM=dumb`. Existing writable guest disks and production rollout are outside
the authorized change. Native fixtures run nested Firecracker guests on one
physical runner; they do not establish independent physical-host availability
or a new production isolation guarantee.
