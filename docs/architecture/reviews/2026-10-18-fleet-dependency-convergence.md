# Fleet dependency convergence (2026-10-18)

## Scope and architecture impact

This review investigates the reported Lilly hostd failure and blocked ordinary
SSH routing. The repair preserves [ADR-0030](../decisions/0030-nixos-deployment-and-tls.md)'s
source-built releases, [ADR-0159](../decisions/0159-remove-legacy-compatibility.md)'s
strict converged formats, [ADR-0176](../decisions/0176-host-concurrency-single-writers-and-effects.md)'s
hostd authority and [ADR-0199](../decisions/0199-memory-suspension-and-demand-wake.md)'s
current inventory contract. No decision or protocol changes. The existing
lock-snapshot equality check remains mandatory.

## Findings and forward repair

Read-only inspection found both hosts' Lilly and hostd services running without
restarts. Dungarees' Lilly emits the current six-field inventory containing
`checkpoint_compatibility`, while Overalls still serves the older protocol.
The ordinary CLI reports `SSH proxy unavailable`. A live process alone does not
establish working inventory or ingress, and administrative SSH is separate
evidence.

Both updaters target `ae783fdbe` but report build failures. The failed Porsche
release stops at the existing `cmp mix.lock "$MIX_DEPS_PATH/.overalls-mix.lock"`
guard. Its cached fixed-output dependency directory retains Hegel `8fe9786`,
while the declared lock requires `b0dec2a`. Comparing all eight applications'
retained snapshots with their current locks found the same mismatch in Marshall;
Audi, Brady, Enrico, Galileo, Lilly and Ziggy match exactly.

Refresh only Marshall and Porsche's reviewed dependency hashes through the
[pin registry](../../../nix/domains/artifacts/default.nix), keeping the current
lockfiles and all source/security changes. Build the clean releases and allow
normal forward deployment to converge. Do not broaden hostd's command grammar,
remove the snapshot guard, accept both inventory formats or roll back suspension.
Successful dependency fetching alone is insufficient: release compilation,
activation, fresh host reports and an ordinary CLI request need separate results.

## Verification and limits

The eight-way snapshot inspection and deployed service/version observations are
recorded above. The refreshed Porsche source-built release and
`checks.x86_64-linux.porsche-release` both passed, producing
`/nix/store/4jf06n1iawjk1fi2a93crrr7n8n5hjzy-overalls-porsche-0.1.0`;
local logs are `/tmp/porsche-final.log` and `/tmp/porsche-release-check.log`.
The current Lilly source-built release also exited 0, recorded in
`/tmp/osmatrix-lilly-current-release.log`. These results describe the pre-merge
worktree source snapshot, not deployed convergence. Marshall compilation,
post-integration gates, fresh reports from both hosts and an ordinary CLI
request remain pending in this checkpoint.

Integration also exposed a deployment assertion requiring disabled Peach and a
closed Audi decoder rejecting its emitted socket field. The repair keeps Peach
optional, emits null when disabled, validates configured bounded local socket
paths, and refuses reflection before authority admission when absent. Existing
Lilly/Ziggy/Galileo dependencies remain. This source repair does not enable
production reflection or establish enabled socket/credential acceptance.

Post-pull `3e25e8218` verification passed Audi's focused configuration suite:
**15 tests**, seed **719595**, in **0.6 seconds**, covering optional socket
validation and early disabled-reflection refusal. The `ziggy-configuration`
Nix check passed in **11 seconds**, and both enrolled host failed-assertion
projections returned `[]`. The source-built `service-audi` release passed in
**24 seconds**. Logs are `/tmp/cli-routing-audi-config-test-final.log`,
`/tmp/cli-routing-ziggy-evaluation.log`,
`/tmp/cli-routing-{overalls,dungarees}-assertions.json`, and
`/tmp/cli-routing-audi-release.log`. These results establish source/configuration
acceptance only. Audi's full precommit test stage subsequently passed **229 of
230 tests**; the sole failure is the known out-of-scope Inception suspended
renewer property. The gate is not recorded as fully passing. Separately,
`MIX_ENV=test` forced Dialyzer passed with **0 errors and 0 skips**; Covenant
static and runtime coverage checks passed **10 of 10 obligations**, with the
isolated runtime run passing **10 tests** in **0.09 seconds**. Logs are
`/tmp/cli-routing-audi-precommit.log`,
`/tmp/cli-routing-audi-dialyzer-test.log`, and
`/tmp/cli-routing-audi-covenant-final.log`. These BEAM results do not establish
native routing or guest isolation.

Before the Peach schema follow-up, both complete enrolled host toplevel
derivations evaluated successfully: Overalls to
`/nix/store/nckdf1yh6h5afpkqdh9sjk944hn848in-nixos-system-overalls-26.05.20260914.c3eea5b.drv`
and Dungarees to
`/nix/store/3rdmk83jq6lsvrzjz6fph0nn1ybgm4nv-nixos-system-dungarees-26.05.20260914.c3eea5b.drv`.
Logs: `/tmp/osmatrix-overalls-toplevel-eval.log` and
`/tmp/osmatrix-dungarees-toplevel-eval.log`. Derivation evaluation does not build
or activate either system.

The latest production observation still had no fresh routes at either gateway.
Overalls' current host report was fresh at about one second old; Dungarees' report
time was nil. The stored Windows fixture route matched its
VM binding but was expired. Ordinary CLI routing remains unavailable or
unverified pending converged releases and fresh control reports; a clean build
does not establish activation or a successful ordinary SSH request.

No destructive guest operation, hostd restart or production database mutation
was used for diagnosis. This repair does not qualify the separate Windows
browser editor candidate or establish guest isolation or recovery.

## Integrated build and activation follow-up

The integrated `1451c0b00` source build passed for Marshall, Lilly and Porsche;
log: `/tmp/osmatrix-final-integrated-releases.log`. Marshall produced
`/nix/store/s8gf2avrpfvlq8k94cjf2y2gzybh3lbg-overalls-marshall-0.1.0`, and Lilly
produced `/nix/store/pmd069rvidsp1r3k08zdm5wmrp5z2cw1-overalls-lilly-0.1.0`.
This build captured source before the later typespec, test-assertion and
formatter follow-ups; it does not establish their complete gates or activation.

The Overalls activation attempt then failed before Marshall served requests.
The newsletter `190000`, reflection `190001` and Peach reconciliation `213000`
migrations had all applied; this was not a schema failure. The GitHub
restore-credential invalidation pre-start wrapper omitted the shared mail
environment used by serving, migration and operator wrappers. With the local
SMTP relay enabled, inherited remote mail settings caused runtime mail
configuration to refuse startup. The forward repair applies that same reviewed
mail environment to the pre-start command; it changes no OAuth, inventory or
guest-authority validation. The serving wrapper also keeps all environment
removal options before the optional bootstrap assignment. Successful activation and ordinary CLI routing still
require a fresh observation after the repair.

The final `module-configuration` check passed in **73 seconds** after both
wrapper repairs. It evaluates all three relay providers and all three pre-start
commands for local-relay selection, loopback SMTP and inherited credential
removal, and an explicit bootstrap package checks serving-option ordering.
Both enrolled serving/pre-start scripts also passed `bash -n` after Nix
evaluation. Log: `/tmp/cli-routing-mail-module-configuration-final.log`.
These are configuration and shell-syntax results, without a new activation or
SMTP delivery claim.

During this partial rollout, Dungarees' newer six-field inventory reached the
older Overalls control plane, which refused it before recording a host report.
The resulting absent current report also explains the Windows fresh roster
request's 403. Running Lilly/hostd processes do not establish converged control
authority. No validation relaxation or manual service restart is acceptance
evidence for this checkpoint. The long Marshall full gate was interrupted when
the agent-owned session ended after model-capacity failures, without a final
test count or summary. Its observed failures include the two now-corrected
CSP/date assertion fixtures, Teams SSH and Pins property database/time-limit
failures, and a Customer inference authorization contract violation. No complete
Marshall passing result is recorded here. The mandatory
formatter's thirteen Marshall source/test diffs
were reviewed as formatting only; the additional time-zone change corrects an
English documentation example without changing its CLDR formatter.

## Customer private-service boundary restoration

The Customer capability policy had accidentally included generic
`:private_services`, contrary to its closed-capability contract and ADR-0064.
The repair restores exactly SSH, terminal and editor capabilities. Lilly's
private execution binding checks the dedicated SSH capability, preserving owner
SSH and exact boot-roster/host-certificate purposes. Audi refuses every non-SSH
service from the Customer `10.10/16` range before requesting a Lilly binding;
inference, reflection, GitHub/ordinary integrations and telemetry gain no
exception. This restores existing ADR-0064, ADR-0158 and ADR-0203 boundaries
without changing domain ownership or the wire protocol.

Focused warnings-as-errors runs passed: Protocol **4 passed**, seed **8487**
(`/tmp/windows-customer-protocol-focused.log`), including the closed-capability
property's 100 cases with seed 761162639; Audi **21 passed**, seed **153872**
(`/tmp/windows-customer-audi-focused.log`); and Lilly **18 passed**, seed
**530280** (`/tmp/windows-customer-lilly-focused.log`). The Audi test
`Customer refuses every non-SSH private service before binding` exercises both
ends of the Customer address range with Plug connections and a local Unix-socket
fixture; its SSH and non-Customer controls preserve the permitted paths. Lilly's
`customer actor allows private SSH binding but rejects web` checks the retained
binding. These BEAM/property results establish bounded policy and connector
behavior, not native packet isolation, browser access, production activation or
Windows editor acceptance. Existing native and recovery gaps remain.

After the restoration, Marshall's focused Requests, CSP and date-component run
passed **18 tests in 3.6 seconds**
(`/tmp/osmatrix-marshall-boundary-and-assertions.log`). It covers Customer
authorize/admit/renew refusal and the corrected CSP/date assertions. This does
not replace the interrupted full Marshall gate or resolve the separate Teams
SSH/Pins property failures.
