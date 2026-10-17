# Native guest coding CLIs and Ziggy beta Messages

Date: 2026-10-13. Scope: pinned Codex and Claude Code in both guest families,
native provider settings and verified trust, and the exact native Anthropic beta
query allowance. User authorization covers implementation, verified merge and
deployment. Pi, OpenCode, custom launchers, model synchronization and production
Anthropic enablement are excluded. The feature checkpoint `b2eb1326` was merged
with main `14f87c0d49b7f482a66f3e5a7c10776a1eb95611` as
`7333a043b643f52989a854d186114caffab7be07`, followed by the reviewed test-fixture
and documentation checkpoint `c57478689ed381afcfcb74178c9b4729139e06c7`.
Integrated results below are separate from the retained earlier captures.
Marshall, the earlier complete NixOS native suite and the corrected complete
Ubuntu native suite passed. Both original Ubuntu failures and their unknown
historical cause remain recorded. The corrected/refrozen packaged handbook browser
check also passed at its captured source. The new action exercised exact reuse in
Ubuntu. Published `8930a70f` activated healthy on both hosts, but the first
production NixOS Codex canary timed out before any inference admission; cleanup
was confirmed and Ubuntu creation was not issued. Device-only replacement and
successful production canary acceptance remain pending. Separate legacy-leaf
TLS proof, same-root preparation and independent encrypted host replacements
are scoped below; no live replacement is claimed by these checkpoints.

## Architecture assessment

ADR-0167 adds a scoped Ubuntu application-closure exception while preserving
ADR-0068's authenticated archive rationale and inherited ADR-0094/0153/0158
offline registration/GC-root contracts. Existing writable disks remain unchanged.
These clients run under guest user permissions and keep guest-local sessions;
they are separate from ADR-0099/0100's Marshall-owned platform agent loop.

The beta query allowance completes the native Anthropic routing contract carried
from ADR-0063. Query validation remains closed, native request bytes remain
native, and query-free accounting operation names stay stable. Marshall admission,
execution renewal, provider-secret custody, replay policy and durable receipt
handling under ADR-0149 are unchanged.

The later leaf preparation and encrypted replacement implement ADR-0111's
existing exact-name and same-root recovery-issuer decision. They add no issuer, signing service, host
authority or native-client trust override. Root/intermediate custody, independent
host payload preservation, publication, live TLS and production client acceptance
remain distinct verification stages; ADR-0111, ADR-0167 and ADR-0168 remain
partial.

ADR-0168 records the image policy, which intentionally selects Codex
`approval_policy = "never"` and
`sandbox_mode = "danger-full-access"`, plus Claude
`permissions.defaultMode = "bypassPermissions"` and `sandbox.enabled = false`.
This removes client prompts and client-level command sandboxing for the isolated
guest image; it does not add inference authority or remove the guest OS, VM,
network or Marshall boundaries. Native probes assert these settings and execute
ordinary client commands without launch flags.

The ZFS observation/preparation contract comments now agree with ADR-0163:
coherent usage-only drift receives at most three complete observations, 25 ms
apart, returning the latest coherent tree if counters keep moving. Identity,
non-usage policy and exhausted accounting failures still refuse; genuine
`storage_busy` stays retryable before VMM launch. This corrects stale contract
wording, without changing the observation implementation. The native refusal
fixture now injects genuine parent-accounting incoherence. The clone fixture
preserves ADR-0145/0159's ordinary same-pool claim/copy journal and uses a genuinely
distinct source zpool for receive assertions, rather than manufacturing receive
history for a same-pool clone. Both changes preserve the accepted boundaries.

The handbook CSS repair preserves ADR-0122's section delivery and ADR-0161's
scrollable diagram-canvas exception: diagram containers contain horizontal
scrolling and SVGs retain the readable 576px minimum. No route, hook, asset
provenance, colour or authority changed.

There is no new Ash domain/resource, host, deployable service or listener. Domain
ownership and topology remain unchanged. Public guest CA trust, Audi's derived
caller identity, Lilly execution fencing and Customer inference refusal remain
the authority boundaries; native configuration and nonsecret sentinels cannot
replace them. Independent source/contract reviews found no actionable boundary
issues in the final reviewed package, routing, allocation/clone, owner metadata
and foreground-timeout changes. Source review is not runtime acceptance.

## Findings and remaining boundaries

- Production hosts select only OpenAI. Claude returns `provider_unavailable`
  until Anthropic is separately enabled and credentialed.
- Native client model catalogs and choices may differ from Ziggy's live catalog;
  no synchronization is promised.
- Codex system defaults and Claude managed environment use their native
  precedence. Guest root can modify installed files; configuration is not
  inference authority.
- Fixture execution cannot establish live providers, sustained capacity,
  independent physical-host failure tolerance or upgrades of retained disks.

## Integrated evidence at 7333a043

The integrated Protocol/Lilly/Ziggy pipeline passed, exit 0:
`/tmp/kittens-cli-integrated-core-precommit.log`.

| Application | Passing checks | Test seconds | Forced Dialyzer seconds |
| --- | --- | ---: | ---: |
| Protocol | 257 (98 properties, 159 tests) | 416.0 | 2.94 |
| Lilly | 540 (106 properties, 434 tests) | 79.6 | 14.11 |
| Ziggy | 71 (17 properties, 54 tests) | 69.1 | 5.22 |

All three typing runs reported zero errors. All-files prek and the evaluated Nix
`hldd` gate also passed at that integrated snapshot. Later test-fixture changes
require their current reviewed receipts and checks; these results do not establish
native isolation or deployed-provider acceptance.

The subsequent `c5747868` checkpoint passed all-files prek, including Ruff
format/check, ty and fleet logging, plus generated options, architecture views,
conflict markers and the evaluated Nix `hldd` gate (6 seconds).
Captures: `/tmp/kittens-cli-prek-c5747868.log` and
`/tmp/kittens-cli-hldd-c5747868.log`. Root reviewed the corresponding source and
handbook changes before recording receipts; this documentation task did not
refresh them. Later evidence updates still require their reviewed documentation
checks, without changing these captured executable results.

The final pre-publication checkpoint separately passed all-files prek, including
Ruff format/check, ty, logging, conflict and reviewed HLDD receipts, and the Nix
`hldd` gate. Captures: `/tmp/kittens-cli-final-prek.log` and
`/tmp/kittens-cli-final-hldd.log`; the latter built
`/nix/store/4wf7yd979pjby9gfn3qyaqqixfnc31nj-kittens-hldd-check.drv` and confirmed
current receipts, references, Ash and evaluated deployment views. Normal commit
hooks passed before publishing `8930a70f`. These captured structural results
precede the later operational evidence prose and establish neither live client
inference nor its subsequent reviewed receipts.

Exact integrated enrolled-host image graphs built and passed protocol manifest
validation in 146 seconds. Both host configurations select the same respective
outputs; all six kernel/initrd/rootfs byte counts and SHA256 values independently
match their manifests. Capture:
`/home/ghuntley/.local/state/nix/build-logs/1791925022547-3865405-0.jsonl`.

| Image | Rootfs bytes | Image identity |
| --- | ---: | --- |
| NixOS | 4,311,261,184 | `sha256:ec136247550bbe480208ba127b35474dadb11225ace1d377d82877cfb7bc3bed` |
| Ubuntu | 2,818,572,288 | `sha256:30be57160c87a15f8ce413e87940f891ca90aaaa037ecf0524a226567f7c6b02` |

Outputs are `/nix/store/xglfvg2pvg8cfw7awgca6faz8wvik576-lilly-nixos-x86_64`
and `/nix/store/jyj9vwkjjhrznnp8sq8rpf5v0cdvnx3n-lilly-ubuntu-26.04-x86_64`.
They retain the 7/5 GiB minimum disks, editor-derived 2 GiB RAM and boot source
protocol 2. Host evaluation is not activation. The exact enrolled-root Ubuntu
derivation `/nix/store/4ydlmr0aky1qlf7pv0gpw3nh1h02y43n-lilly-ubuntu-26.04-x86_64-rootfs.drv`
then passed `--rebuild`, exit 0, in 72 seconds. Before/after length remained
2,818,572,288 bytes and SHA256
`9c12f08a449339a36497a576fd73f5dee35e795f107ff7d0d4c0724bb18fc1c2`;
the image identity remained unchanged. Capture:
`/home/ghuntley/.local/state/nix/build-logs/1791925245773-3959161-0.jsonl`.
This closes integrated Ubuntu reproducibility on this builder, separately from
cross-host publication and retained-disk upgrades.

Both complete integrated coding-client fleets passed with no source changes
during their runs: NixOS 352.54 seconds and Ubuntu 432.98 seconds of driver
execution. Captures are `/tmp/kittens-coding-clis-nixos-fleet-final.log` and
`/tmp/kittens-coding-clis-ubuntu-fleet-final.log`; runtime derivations are
`/nix/store/6x1388ks83i5pzdsqp3fpxybha5dbllp-vm-test-run-kittens-coding-clis-nixos-fleet.drv`
and `/nix/store/39cxcw6zdvdd6450696j2bjd47b057b0-vm-test-run-kittens-coding-clis-ubuntu-fleet.drv`.
Both executed actual pinned clients with unchanged native settings in genuine
canonical-account PTYs, verified Audi/private/provider TLS, current real Marshall
admission, independent provider counters, native guest GC and registered verified
Audi SSH inference from both clients after GC. Both completed Customer client and
route refusal without provider effects and cleaned up. Exact beta token counting
uses a separate guest curl request; it is not attributed to Claude. The NixOS
combined remote-client command passed in 4.72 seconds; Ubuntu's registered-SSH
subtest passed in 99.74 seconds and Customer refusal/cleanup in 127.83 seconds.
Valid-unrelated-root Codex refusal and curl hostname/parser checks retain the
limited trust scope described below; every Claude trust failure is not claimed.

These fleets select the shared native packages/settings with isolated public
roots and omit the unrelated browser editor. Their test image identities are
distinct from the enrolled-host editor-bearing production artifacts above. For
example, the Ubuntu fleet image is
`/nix/store/5pvfzqvgnz754616qv66ydls69inkdz1-lilly-ubuntu-26.04-x86_64`, with a
2,952,790,016-byte rootfs, SHA256
`87a5974fa22a2761a1cc4f32cb8c8f13988f6922f2dbcf729369ed0e4e6e0f06`
and a 512 MiB manifest minimum. The test requests 2 GiB guest RAM. Fleet passes
establish the actual client/trust/authority journeys in those fixture images,
not live providers or activation of the production artifact identities.

Both integrated full native drivers built in 230 seconds; build-only capture:
`/tmp/guest-native-drivers-merged7333a043.log`. The complete packaged NixOS native
check passed, exit 0, with its original fourteen subtests and no script override.
The script summary reports 3,699.75 seconds (VM script timing 3,699.72 seconds),
followed by 0.78-second cleanup; no matching task QEMU or runtime sockets remained.
Derivation:
`/nix/store/sdwc7pl5sx1dl0zf0izqq4zlgjpwndpb-vm-test-run-kittens-zfs-guest.drv`;
output: `/nix/store/syl71pavc0fpbzrk51x08z81dfz39npb-vm-test-run-kittens-zfs-guest`;
capture: `/tmp/guest-native-zfs-7333a043.log`. Evaluation at `c5747868` selects this
exact same derivation as the running `7333a043` check: intervening changes affect
only Marshall's test fixture and documentation, not native executable inputs.
The native client/settings/GC subtest passed in 24.72 seconds, including the
explicit `FORCE_AUTOUPDATE_PLUGINS=0` assertion; source probe took 62.64 seconds.
Initial confinement/launcher-survival/sparse storage passed in 532.71 seconds,
including the 17.35-second parent-incoherent restart refusal. Host-loss
persistence passed in 138.97 seconds, older-guest deletion in 327.81 seconds and
readiness in 50.50 seconds. Genuine cross-pool receive, clone data independence,
strict staging/restart refusals and fenced cleanup passed in 464.60 seconds,
including the final pre-attempt cleanup deadline guard. The final Inception
clone passed in 321.69 seconds. These are native same-host NixOS results, not
independent physical-host or deployed-provider acceptance.

The serialized full Ubuntu check failed, exit 1, when starting fresh neighbour
102 after reboot: `{:error, :template_quarantined}`, with image-template revision
5 changing from ready to quarantined. Capture:
`/tmp/guest-native-ubuntu-7333a043.log`; derivation of both original full captures:
`/nix/store/fnr30w0vrxkgfs0s6xz55zhzzfd3hryn-vm-test-run-kittens-ubuntu-guest.drv`.
Cleanup finished in 0.68 seconds. Before this failure, the current native
client/settings/login-CA/GC checks passed in 13.86 seconds, including the explicit
plugin-update assertion; the isolated typed-source probe passed in 71.22 seconds,
initial confinement/launcher-survival/sparse storage in 328.00 seconds and
host-loss persistence in 72.54 seconds. The failed broad run does not establish
complete Ubuntu lifecycle, current clone/receive or cleanup-guard acceptance.
Its template-quarantine cause and recovery outcome remain under investigation;
earlier focused Ubuntu clone evidence retains its separate source scope.

A focused Ubuntu diagnostic passed, exit 0, in 507.23 seconds, followed by
0.75-second cleanup: `/tmp/guest-template-witness-ubuntu/capture.log`. It augments
the original journey with read-only template witnesses before the crash, after
pool import and before the fresh neighbour. All eleven identity fields matched
for all four files at each phase; native ownership/seal/readability and complete
hash predicates also matched, with the template remaining ready at revision 4.
The original VM 102 start/write succeeded, so the failure did not reproduce.
This instrumented capture stops at that boundary and is not complete packaged
Ubuntu acceptance. The original failed build discarded its runtime state, so
these later matching witnesses cannot establish its cause. Production template
and identity code remains byte-identical to main `14f87c0d`; no repair was made.
The exact unchanged packaged Ubuntu rerun, with failed-state retention and no
injected probes, failed again at VM 102 startup with `template_quarantined`.
Capture: `/tmp/guest-native-ubuntu-recheck-c5747868.log`; cleanup took 0.71 seconds.
Before refusal, its client/GC, typed-source, initial confinement and host-loss
checks passed in 17.61, 61.39, 333.86 and 69.24 seconds respectively. Its failed
builder and private QCOW copies were retained. These two failed full
runs remain separate from successful diagnostic slices and do not establish
complete Ubuntu acceptance.

Inspection of that retained state after a new boot/import passed in 25.57 seconds
with 0.23-second cleanup:
`/tmp/guest-template-retained-inspection/inspection.log`. The journal remained
quarantined at revision 5. All ownership, seal, readability and complete artifact
hash predicates passed, but only identity field 0 (`st_dev`) differed for all four
files; the other ten fields matched. `Image.sealed/2` correctly refused the exact
identity mismatch. This demonstrates strict sealed refusal in the inspected
post-import state. The inspection itself imported the pool; it cannot prove the
original failure-instant predicate or establish the historical cause.

A subsequent same-builder diagnostic armed a witness only after an actual
refusal. It passed in 449.24 seconds with 0.74-second cleanup:
`/tmp/guest-template-live-failure-witness/capture.log`. The original VM 102
start/write passed in 28.09 seconds; the failure witness never activated. It
stops before older-guest deletion and neighbour-survival assertions and supplies
no live failed predicate. Neither successful diagnostic repairs or explains the
two original full failures.

### Limited post-import cache fixture

The test-only [post-import action](../../../nix/verification/tests/machines/zfs-guest/template-post-import.exs)
explicitly tests the public cache before VM 102 startup. Exact identities may
reuse the ready incarnation. A demonstrated device-only mismatch must retain
strict sealed refusal without entering the reader callback, quarantine the old
incarnation by one revision, retire
and delete it by three revisions, and fully hash a distinct fresh incarnation
through ready revision 4. Any other mismatch or refusal fails the fixture; this
is not a generic retry. Successful native owner and mount reads must confirm
absence, and old artifacts must be absent. A destroyed dataset may leave a
private empty unmounted directory, so the test does not require or perform an
extra unlink. The action preserves the stable `owner.lock` identity and cannot
grant VM intent, launch-attempt, boot, placement-dataset or execution authority.
Production template identity/recovery source and canonical terminal Executor
quarantine remain unchanged.

This fixture handles positively observed remount identity behaviour without
claiming a repair for the unexplained original failures. It preserves
ADR-0130's exact sealed identities and fenced retirement/full-verification
rationale; no replacement decision or production recovery policy is introduced.
Only existing catalogued lifecycle events are emitted. Corrected Ubuntu and
focused current NixOS exact reuse passed below. Device-only replacement and final
gates remain unexecuted/pending.
The earlier complete NixOS pass predates this fixture addition and cannot establish
its new branch coverage. A passing action must record which of `:exact` or
`:device_only` executed; exact reuse alone cannot establish fenced replacement.
These native journeys use customization fixture images, separately from the
exact built enrolled-host artifacts and production activation.

### Corrected Ubuntu native acceptance

The complete corrected packaged Ubuntu suite passed, exit 0, with all twelve
completed subtests (ten outer and two nested). VM script timing was 2,203.21
seconds, the driver summary 2,203.23 seconds, followed by 0.75-second cleanup.
Derivation:
`/nix/store/gf2zw4xfa337z8zl6qnw5zsjc5zdny7f-vm-test-run-kittens-ubuntu-guest.drv`;
output: `/nix/store/fly7rc3ippg6hqr7l63a24vd8afwqx57-vm-test-run-kittens-ubuntu-guest`.
Capture: `/tmp/guest-native-ubuntu-corrected-33800c7f.log`, SHA256
`f3a0feea43167e6977bb3b0d55043ad712c2ab8efa2ebaf73fb07689f75a06d4`.
The helper source remained unchanged, SHA256
`33800c7f754062d07184c4a459ce8e4e53c5b8574ffeae060a7ad1d7008c8ca2`.
Current client/settings/GC passed in 15.13 seconds, including the plugin-update
assertion; typed source in 81.12 seconds, initial confinement in 359.33 seconds
and host-loss persistence in 73.36 seconds. The clone/receive journey passed in
392.45 seconds, including the final cleanup deadline guard; final Inception
multidisk clone passed in 258.52 seconds.

The post-import action passed in 22.26 seconds, within a 40.85-second subtest.
It exercised `:exact` reuse: scoped lifecycle events show only the original
template's staging/verifying/sealing/ready revisions 1..4, with no quarantine,
retirement, deletion or replacement. VM 102 subsequently materialized from that
same record/incarnation and its ordinary startup passed in 20.06 seconds.
This establishes the exact-reuse branch and the complete corrected Ubuntu native
lifecycle, not the device-only quarantine/replacement branch. The two earlier
full failures and later imported inspection remain separate; the successful
corrected run does not identify their failure-instant cause or claim a production
guard repair. This uses a customization fixture image, not activation of the
production artifact or live provider acceptance.

### Focused current NixOS acceptance

The focused current NixOS check passed, exit 0, using the exact 200-line current
packaged prefix. It completed six subtests (four outer and two nested), through
the original VM 102 full deletion, export, retirement, refusal and zero-allocation
cleanup. VM script timing was 1,246.93 seconds, the driver summary 1,246.95
seconds, followed by 0.72-second cleanup. Derivation:
`/nix/store/pj4z7h7i2g6cq7bjmk6r8sk6663zz36m-vm-test-run-kittens-zfs-guest-post-import-focused.drv`;
output: `/nix/store/982my2h8w5cyxyfxds8x0nbbmcmxmwhd-vm-test-run-kittens-zfs-guest-post-import-focused`.
Capture: `/tmp/guest-native-nixos-post-import-focused-33800c7f.log`, SHA256
`59657a3aebac0f78a6263dc425f93a043a3ec31615f432c2cd95ca0fee8271a5`.
The helper retained the exact SHA256 recorded above. Host-loss persistence took
131.75 seconds; the post-import action passed in 36.53 seconds within a
74.89-second subtest. VM 101's actual process/read/observe oracles were retained;
ordinary VM 102 startup/write passed in 34.74/31.44 seconds.

This also exercised `:exact`: scoped action events contain no template lifecycle
transition, and the original template remains ready at revision 4. Device-only
quarantine/retirement/deletion/replacement remains unexecuted in both final native
runs. The later 161 lines were omitted from this focused check and retain only
the earlier complete NixOS pass's scope. This is current prefix acceptance,
not a second complete current NixOS run, deployed recovery or an explanation of
either original Ubuntu failure.

Independent final source/contract review covered the exact helper SHA256
`33800c7f754062d07184c4a459ce8e4e53c5b8574ffeae060a7ad1d7008c8ca2`
and its four-file fixture change: helper, `default.nix`, `probe.exs` and `driver.py`.
It found no actionable findings in the final hash or wiring, including exact
classification, callback-free refusal, monotonic replacement, successful native
absence and preserved launch authority. This was source-only review; recorded
native exact-branch acceptance is separate, and the replacement branch remains
unexecuted. Production template/identity/Executor guards are unchanged.

The final milestone source/contract review of `c5747868` against main `14f87c0d`
found no actionable violations. Independent review confirmed finite MFA owner
timeout forwarding, defaults and cleanup with no production authentication
architecture impact; image/template/identity, native helper, Lifecycle, Executor,
Intent and Boot source remained unchanged, with no guard weakened. ADR-0167/0068
and ADR-0063/0113 boundaries remained intact. This source-only review inspected
raw application/native/fleet evidence; it does not establish execution of the
later post-import action, independent-host behaviour or deployment.

Marshall's integrated run had one MFA history fixture failure: the unchanged SQL
sandbox owner's 120,000ms lifetime expired while mounting `live("/overview")`.
It passed 1,475 of 1,476 checks (238 of 239 properties and all 1,237 tests), with
four excluded, no invalids, in 1,596.9 seconds. Forced Dialyzer reported zero errors
or skips in 49.99 seconds; all 32 terminal tests, eight workspace tests and
Monospace checks passed, and task peers were cleaned up. Capture:
`/tmp/kittens-guest-marshall-precommit-merged.log`.
No MFA assertion failed. The twenty-history property and its complete operation
matrix/oracles remain intact. The two-file repair adds a 240,000ms owner tag to
that module, matching its existing test timeout; `DataCase.setup_sandbox/1`
validates an explicit integer tag in 1..240,000ms and forwards it to the owner,
preserving the configured default when absent, async sharing rules and owner
cleanup. This has no architecture impact on production authentication, MFA
lifetimes, refusal or authorization. The same-seed MFA targeted retry passed,
exit 0, in 91.7 seconds: one property, all twenty histories/oracles, seed `922579`,
pinned `MIX_ENV=test` with `+S 4:4`. Capture:
`/tmp/kittens-guest-marshall-mfa-owner-retry-test-env.log`. It finished below the
original 120-second owner budget, so it does not establish stress or owner-expiry
boundary execution. The failed full run identifies the mismatch and source review
verifies the finite override. The first interrupted target capture from a
development-format attempt has no final summary and provides no acceptance.

The complete current Marshall precommit then passed, exit 0, at `c5747868`:
1,476 checks (239 properties and 1,237 tests), four excluded, no invalids or
failures, in 1,400.4 seconds, seed `81323`. Forced Dialyzer reported zero errors,
skips or unnecessary skips in 49.94 seconds. All nineteen contract-validator
regressions, 32 terminal tests, eight workspace tests and Monospace checks passed;
task peer `575520` was verified absent and diff checks were clean. Capture:
`/tmp/kittens-guest-marshall-precommit-owner-final.log`. This verifies the complete
application gate with the bounded fixture fix, separately from the targeted
retry's limited timing scope. No local compilation was performed by this
documentation task.

## Earlier image and application evidence

The exported default images built in 100 seconds with
`nix build --no-link --json --max-jobs 1 --cores 4 .#guest .#ubuntu-guest`.
With `privateServiceRoots=[]`, NixOS rootfs measured 4,311,171,072 bytes and a
7 GiB minimum disk; Ubuntu measured 2,818,572,288 bytes and a 5 GiB minimum.
Capture: `/home/ghuntley/.local/state/nix/build-logs/1791918257296-1070416-0.jsonl`.
Ubuntu's exact same-derivation rootfs `--rebuild` passed in 94 seconds with
identical SHA256 `85ad0fb592b91023031aac8850fae9f08e4f9fe5ad0ca3dd6ae7927c177d9ead`
and length. Capture:
`/home/ghuntley/.local/state/nix/build-logs/1791918413923-1137681-0.jsonl`.
This establishes reproducibility of that exported graph on this builder.

The enrolled-host image graph with platform public roots also built in 160
seconds, and both manifests passed protocol `validate/1` in the pinned shell:

| Image | Rootfs bytes | Minimum disk | Image identity |
| --- | ---: | ---: | --- |
| NixOS | 4,311,261,184 | 7 GiB | `sha256:1749e25437550f7229c8570fb6b8ac1782877e3d01fa7d50baa6fec57c4f739b` |
| Ubuntu | 2,818,572,288 | 5 GiB | `sha256:e0e9c848b5472d5f85e8a7fd9947ae140d1fd8e17f79a25255aaad992989c47d` |

Both retain the existing editor-derived 2 GiB minimum RAM. Outputs are
`/nix/store/c4s2l6q537n2pybwsc0hfq646q0n62a2-lilly-nixos-x86_64` and
`/nix/store/j9zzbj3gfzbvv5vhd4236xcxyifzvm2v-lilly-ubuntu-26.04-x86_64`;
capture: `/home/ghuntley/.local/state/nix/build-logs/1791918818355-1349235-0.jsonl`.
These captured feature artifacts precede the later integrated publication and
activation recorded below; their source-specific evidence remains separate.

`guest-toolset` and `ubuntu-guest-unit` passed, including the latest eight-second
run. Native settings, certificate environment and offline registered closure
assembly were evaluated. Host package version/help also passed for `codex-cli
0.149.0` and `2.1.238 (Claude Code)`. Serialization/closure checks and all-files
Ruff format/check plus `ty` passed; composed machine drivers retain their native
NixOS type-check scope.

The feature Ziggy gate passed under Elixir 1.20.4/OTP 29.0.6 with 71 checks
(17 properties, 54 tests), seed `656833`, in 68.1 seconds; forced Dialyzer
completed in 5.61 seconds with zero errors/skips.
Capture: `/tmp/ziggy-codex-claude-precommit.log`.
The feature Lilly gate passed 540 checks (106 properties, 434 tests) in 62.8
seconds, with zero-error/skip forced Dialyzer in 12.36 seconds after the 132.5-second
PLT build. Capture: `/tmp/kittens-guest-lilly-precommit.log`.
Neither gate establishes incoming-main integration or native isolation.

The earlier Marshall gate passed 1,433 checks (237 properties, 1,196 tests),
with 42 invalid and four excluded, and zero-error/skip forced Dialyzer. Concurrent
synthetic-browser setup compiled 109 files into shared `_build/test` during
admission-peer startup. A serialized same-seed retry passed all 42 admission
checks (two properties, 40 tests), seed `677149`, in 104.6 seconds; peers were
cleaned. Capture: `/tmp/kittens-guest-marshall-admission-retry.log`. The original
full gate did not pass; the complete integrated gate remains required.

## Earlier packaged service and scoped guest evidence

The packaged `ziggy-service` check passed, exit 0, with 86.48 seconds of driver execution.
Derivation: `/nix/store/6yk9jrff4dly9jkd3lsrlpfm7sbr0ypb-vm-test-run-kittens-ziggy-service.drv`;
capture: `/tmp/ziggy-codex-claude-machine-streaming.log`.
Real beta Messages SSE/JSON and native/prefixed token counting reached exact
upstream `beta=true` URLs, preserved native bytes and Anthropic headers, stripped
guest authentication/unknown headers and recorded query-free `messages` and
`count_tokens`. Unsupported query aliases were refused with provider calls remaining
17. This packaged fixture uses isolated verified-TLS providers and synthetic
control authority; it does not establish Firecracker or live providers.

The pre-integration full native attempt passed the individual Codex/Claude/GC probes:
Ubuntu 21.24 seconds and NixOS 29.30 seconds. Both executed real version/help,
inspected native configuration and login CA variables as root and a manually
created plain account, and repeated checks after actual `nix-store --gc`.
Capture: `/tmp/guest-coding-cli-native-accounting-final.log`, lines 2701/3213.
These are client execution/retention results, not inference authority. The new
explicit `FORCE_AUTOUPDATE_PLUGINS=0` assertion was added after that execution;
static checks passed then. The current assertion executed in both integrated
native client/GC subtests above. At the earlier `c5747868` checkpoint, only
NixOS's complete native suite had passed; the corrected complete Ubuntu pass
is recorded separately above.

The same capture records source-probe passes of 41.46 seconds (Ubuntu) and
180.72 seconds (NixOS), plus corrected parent-incoherent restart-refusal passes
of 12.30 and 18.60 seconds. Source probes retain the actual VMM process/GUID,
Transfer.Probe and no-snapshot oracles. Isolated Ubuntu lacks an Audi roster;
its actual `Driver.provisioned` timeout must retain durable `awaiting_ssh`, not
manufacture readiness. Initial attempts exposed fixed fixture sizing below the
existing 2 GiB RAM floor, missing canonical `owner_id`, and obsolete readiness,
usage-drift and same-pool/receive assumptions. These failures are fixture scopes,
not complete client or lifecycle acceptance. That earlier Ubuntu broad run stopped
at the obsolete clone receive assertion; NixOS was cancelled before the same
known failure. The corrected distinct-zpool receive journey subsequently passed
the focused Ubuntu execution below. Current full NixOS acceptance and the later
Ubuntu template-quarantine failure are recorded separately above.

The current receive source uses a third bounded 32 GiB sparse disk, disjoint
backing extents and verified `Pool.distinct?/1`. It exercises production cross-pool
copy, duplicate copy/adopt, genuine import ownership, staging/restart refusals,
revocation, discard/prune and fenced source deletion. Ordinary same-pool clone
checks keep their copy journal and reject receive history. The quiet focused
Ubuntu customer clone journey passed, exit 0, in 476.44 seconds:
`/tmp/guest-clone-focus-ubuntu-quiet.log`. This manually generated-driver subsection
executed the original clone data/divergence/delete assertions, genuine source120
to received121, pending/staged import and three strict `storage_busy` refusals
with unchanged boot/launch/Intent, invalid journal nonce/GUID/malformed bundle
refusals, coherent neighbour restart, receive adoption/replay, fenced cleanup and
GUID-verified source-zpool destruction. An earlier same-source focus reached
receive but failed a three-second metadata timeout; the quiet retry passed without
weakening its oracles. This is focused native same-host Ubuntu scope, not either
complete packaged family check or cross-host transfer acceptance. The later
corrected complete Ubuntu suite above establishes its own final-source scope.
After that capture, source review added a pre-attempt cleanup deadline check so
sleeping between retries cannot issue deletion after expiry. Its final packaged
execution is established by the complete NixOS pass above; current packaged
Ubuntu execution is separately established by the corrected full pass above;
its two earlier template-quarantine failures remain recorded.

The NixOS packaged fleet capture
`/tmp/kittens-coding-clis-nixos-fleet-public-ca.log` passed its native terminal
inference/token-counting subtest in 13.71 seconds, TLS-refusal subtest in 2.50
seconds, and root post-GC version/help helper in 1.91 seconds. Actual image
Codex/Claude used unchanged settings in the reconciled personal-account PTY,
through Firecracker, Audi verified private TLS, real Marshall admission and
isolated provider fixtures. Token counting used guest curl; Claude is not claimed
to initiate it. The provider inventory independently observed requests and
unchanged effects after refusal. This is recorded NixOS subtest evidence only;
at that capture full fleets were pending and Customer was not reached. Both
complete integrated fleet outcomes are recorded above.

Trust refusal uses a valid unrelated CA plus an empty CA directory for actual
Codex; only the negative probe disables unbounded connection retries and sets
request/stream retry limits to zero. Native refusal is nonzero without a timeout
or reply, with generic connection-error wording. Paired positive trust, curl
error 60 and unchanged provider counters provide bounded chain-refusal evidence.
Wrong hostname uses curl; malformed PEM is a separate parser refusal. These
checks do not establish every Claude trust-failure mode.

Registered Audi SSH `true` authentication passed in 106.72 seconds after the
unprivileged client received a readable public CA copy; the credential-bearing
setup directory stays private. The combined remote native-client command then
failed with exit 124 before remote provider effects. Pinned Codex source reads
nonterminal stdin to EOF even with a positional prompt. The fixture now supplies
`ssh -n` and explicit `/dev/null` stdin; both integrated SSH inference journeys
subsequently passed as recorded above.
Foreground-preserving timeout helpers separately fix the proven PTY suspension:
Claude's child group differed from the terminal foreground group, while the
bounded `timeout --foreground` control succeeded. These are test-scaffolding
corrections, without native provider/configuration changes.

One captured host-side Ziggy startup OOM at its 512 MiB fleet override is recorded
in `/tmp/kittens-coding-cli-ssh-live/driver.log`, lines 15713–15795. Only the selected
coding-client fixture now permits 1,024 MiB. Production Ziggy's 4,096 MiB default,
other fleet variants and guest terminald's shared 512 MiB ceiling are unchanged.
Retained guest inference reached that terminal ceiling with 538 reclaim events,
zero OOM/kills, the same daemon PID and zero restarts. This is bounded observed
execution, not a sustained-capacity result or a production tuning recommendation.

## Published deployment and first production canary

`8930a70f488effb152d8ec2787b5728094548f74` was pushed to `origin/main` and
activated healthy on both hosts by 2026-10-14 00:53:46 UTC. The safe operational
capture is `/tmp/kittens-cli-production-8930a70f-20261014-005346`.
`deployment.json` records the exact revision and active systems:

| Host | Active system |
| --- | --- |
| Overalls | `/nix/store/7r0vgpakypb94pikz0ihqd45h4qakc1x-nixos-system-overalls-26.05.20260914.c3eea5b` |
| Dungarees | `/nix/store/fimydav6fpy6m0b25m0s4n62jc5j05qx-nixos-system-dungarees-26.05.20260914.c3eea5b` |

Preflight `images.json` and `offers.json` confirm the production image identities
and respective store outputs recorded above, with fresh matching offers from both
hosts. This is source/image activation evidence, separate from runtime acceptance.

Production run `cli-20261014-005346` failed its first NixOS Codex canary. A
240-second client timeout was reported during execution; the runner's guest
program sets that client limit. Surviving sanitized command metadata records
241.842 seconds of remote execution, exit 1 and `timeout: false` at the outer
420-second bound. Only the exception class and stderr digest survived; no partial
child stderr was retained. There were zero inference admissions; the result
does not supply the original guest's TLS error. VM
`fe7da0da-57b0-4294-b591-0be932c4e1f5` used the production NixOS image, with
preplanned create request `b2cc711a-19d4-4dbe-9a56-ec23d9717e2f` and delete request
`deaf6e29-9d8a-4e64-88fd-1337dc24e40a`. `cleanup-nixos.json` confirms deletion,
released reservations and the sole placement dataset absent; `result.json`
records `native_checks_passed: false`, confirmed cleanup and no unconfirmed
cleanup entries. Ubuntu creation was not issued. This failed production run
remains separate from the passed isolated fleets and native lifecycle fixtures,
and from the unknown cause of the two earlier template-quarantine failures.

## Legacy public-chain proof and same-root preparation

Both public leaves captured at `8930a70f` had `llm.internal`, `*.internal` and
`*.integration.internal`, with fingerprint
`05e4c3ca9dc75dac0599c055429dcecd66a0a6abd79bac7f944f63b0fa2a5bfe`.
Independent offline validation with WebPKI 0.103.13 and PKI types 1.14.0 returned
`Failed(MalformedDnsIdentifier)` for chain validation and `Passed` for
`llm.internal` name validation. The critical DNS name-constrained issuer exposes
the old extra wildcard during chain validation. This proves the captured public
chain's strict rejection, without reconstructing the timed-out guest's stderr.
The verifier `/tmp/kittens-webpki10313-diag` was pinned and separately identified:
binary SHA256 `b7f2b396a750e4a45b803f7e96b524bcf63ef2c150b32bb1c0c5b5c6fb59303c`,
source `a23ecd4fba32ec3dc036c667d378683bc07b95b31776523b7ce7e1684502967e`,
lock `25626dc1f53371137b9344896d2717f111ade3acce971cdb2d5365fc2d01e92c`.

`/tmp/kittens-codex-san-repro-rustls/results.json` records separate local Codex
0.149.0 HTTPS tests with TLS verification enabled throughout. Unconstrained
issuers accepted both the exact names and the old extra name; the constrained
issuer accepted the exact names in 0.14 seconds with one HTTP admission and
rejected the extra name in 0.14 seconds with zero admissions. Bounded wrong-root
verification also refused. Native `SSL_CERT_DIR` passed the exact constrained
chain in 0.30 seconds, while wrong-root and wrong-name controls refused; the
`SSL_CERT_FILE`-only case refused. These are isolated responder counts, not
Marshall inference admissions or a production trust/configuration change.

Sanitized `proof.json` in `/tmp/kittens-private-leaf-20261014-oyA52hLo` records
the subsequent preparation checkpoint: the committed/live/recovered root bytes
are identical, retaining fingerprint
`f9e560a52a4dcbb6ccd308ca46f80f3a43b1e2d47f40ea65653d5c34dfe05292`,
and the live constrained issuer remains
`c581a2b7afcc1d045a90a579c232373f7f6553112d99a31b765ecac4f1e26275`.
The new shared P-256 leaf fingerprint is
`ce5b54113488de22b583e4f89b9e4fc7ad28573d55acf64a77dda821bdc62ca5`,
with exactly `llm.internal` and `*.integration.internal` and expiry
`2036-09-21T10:18:04Z`. Signatures, critical constraints, key usages, EKU,
SKI/AKI and capped expiry were checked; pinned Rust chain/name validation passed
for `llm.internal` and `ssh.integration.internal`. Both independently decrypted
host candidates preserved every nonleaf value and contain no runtime signing
key. Preparation changed no ciphertext at that checkpoint. The frozen helper
SHA256 is `ca57e68a5a8d15d5ae82bf61dd97b883a2c602fb630ca989dca2442e1806427b`;
its sixteen synthetic tests and pinned Python 3.13/Ruff/ty checks passed.
This establishes offline preparation, not encrypted publication, live serving,
both-host Rustls compatibility or renewed production Codex/SSH acceptance.
The retained root requires no guest trust-root replacement or re-imaging for this
leaf change. Earlier retained-disk helper migration is a separate obligation.

The subsequent encrypted replacement checkpoint passed independently for both
host documents. Sanitized `publication-proof.json` in the same public-proof
directory has SHA256
`4a50e0ec5902fbf2f661a818a5121451ebc47faf20149a8762d223b57c1562bb`.
Two sequential `encrypt --replace` operations exited 0, with original pins before
the first, replacement/remaining-original pins before the second and final pins
all verified. Each new ciphertext independently decrypted to its own complete
prepared JSON; only leaf chain/key changed and every host-specific nonleaf value
was preserved. The shared leaf/key, retained constraints/root/issuer and absence
of runtime signer material passed validation. The current authenticated secret
registry checked all 38 documents; this is recipient verification, separately
from the private round-trip and cryptographic checks.

Final ciphertext SHA256 values are
`a0bbec307ce89ec631af3c47d80a0fdd2c41ee71680a12486dc145a46aaf53a5`
for Overalls and
`580f7082f1c4cd3627b136ea81cd9d0ad71d1038c1a0dbc1a0c5281c8384500b`
for Dungarees. Recovery ciphertext SHA256 remains
`34a8075c4d007d1ad974f8139787130ac46cbea72ea5d802b7488b4da97a79c0`;
public root PEM SHA256 remains
`e3ffa51e4a605a2d667f4203018011f785636a655bd775a18f7390b3cf51097f`.
Per-file atomic replacement is not a transaction across both documents. This
checkpoint is encrypted preparation awaiting normal commit/push and deployment;
the earlier captured live chain remains its own scope, and both-host live serving,
Rustls verification and renewed production canaries remain pending.

## Handbook evidence and remaining gaps

The initial mobile handbook failure was confined to existing diagram overflow:
390px viewport/body 529px, with a 504px SVG. Container scrolling corrected body
width, while the independent 576px readability assertion still required the SVG
minimum repair. The unchanged packaged `hldd-browser` assertions subsequently
passed in 58.71 seconds of driver execution (browser subtest 25.40 seconds).
Derivation: `/nix/store/yqajasblwk13n6ia4fm1s4xab5qnisbm-vm-test-run-kittens-hldd-browser.drv`;
capture: `/tmp/kittens-guest-hldd-browser-fixed.log`.
Every captured section/domain/topology diagram, hook cleanup, desktop/dark,
mobile/print, unknown/public route and revoked ordinary-reader refusal passed.
This retains that packaged source scope, before the final checkpoint/integration.

The corrected/refrozen packaged handbook browser check passed, exit 0, on
2026-10-14: the driver summary was 47.18 seconds, VM script 47.14 seconds,
ordinary-reader subtest 22.15 seconds and cleanup 0.49 seconds.
Derivation:
`/nix/store/zydlqlwnii30siqp87wxf3jpsi4zqlqb-vm-test-run-kittens-hldd-browser.drv`;
output: `/nix/store/fm164r2vaa7dlb3vk63yc59lnjhkbk9l-vm-test-run-kittens-hldd-browser`.
Exact packaged source: `/nix/store/13mjsznzzvavzm3qiy48dv25db99sh0m-source`,
NAR `sha256:0k92kd7rkh132j894wbd77ydjiyq3bdx5501fkb8q7sfw09i4c9l`.
Capture: `/tmp/hldd-browser-final-20261014/native-refrozen.log`, SHA256
`0f060f5bc876702117da612a968dd7d650c0dae9a8cc3ebb4cfb39389ac0e56a`.
Its packaged coverage chapter, scenario inventory and configuration reference
byte-matched the corrected frozen sources before this outcome was recorded.
Every current section and reference graph rendered actual SVGs; domain/topology
views, previous-hook cleanup, desktop/dark, mobile containment with the readable
576px canvas, print, unknown/public routes and ordinary-reader role retention
passed. Stored revocation refused both mounted navigation and a stale-cookie
fresh request. This is packaged single-Marshall browser evidence at that source,
not guest inference, production activation or multi-replica acceptance.
The earlier pre-citation-correction run passed in 48.07 seconds;
`/tmp/hldd-browser-final-20261014/native.log` retains that earlier source scope
and does not replace the corrected/refrozen result.

The separate synthetic presentation probe passed in 39.014 seconds against the
final CSS: both themes, 390px mobile layouts, grid, font, contrast, navigation,
drafts, public documentation and no external requests.
Capture: `/tmp/kittens-monospace-browser-final/probe.log`. Presentation/contract
checks and 19 validator regressions passed. The synthetic probe does not establish
guest execution, real inference or deployment.

The earlier checkpoint passed `check_adrs.exs` (165 decisions; structure/local links),
generated-option reference, coverage and architecture-view checks, and
`git diff --check`, in the pinned shell. `check_hldd.exs` correctly refused stale
Marshall, Lilly, services, deployment and governance review receipts; this
documentation task did not refresh them. These are structural results, not final
application or deployment acceptance. The subsequent integrated and reviewed
`c5747868` Nix HLDD passes are recorded above; this new evidence prose still
requires reviewed documentation receipts before its final gate.

Coverage keeps these executed scopes separate from source presence. No Ash
ownership or evaluated topology changed. Current Marshall, static/Nix handbook
and complete NixOS native gates passed at their captured checkpoint. Remaining
acceptance includes the unexecuted device-only replacement branch,
final handbook governance checks, reviewed receipts for subsequent prose,
same-root leaf publication/live verification and successful production canaries.
Live Anthropic remains deliberately disabled; live-provider acceptance,
sustained capacity and independent physical-host behavior stay separate.

## Related decisions

[ADR-0168](../decisions/0168-guest-coding-cli-dangerous-defaults.md),
[ADR-0167](../decisions/0167-native-guest-coding-clis.md),
[ADR-0068](../decisions/0068-nix-built-ubuntu-guests.md),
[ADR-0094](../decisions/0094-default-development-environments.md),
[ADR-0063](../decisions/0063-private-services-and-ziggy.md),
[ADR-0099](../decisions/0099-marshall-owned-agent-threads.md),
[ADR-0100](../decisions/0100-pulled-agent-work-over-ziggy-control.md),
[ADR-0113](../decisions/0113-guest-trust-at-boot.md),
[ADR-0122](../decisions/0122-hldd-section-pages.md),
[ADR-0130](../decisions/0130-verified-provisioning-fastpath.md),
[ADR-0145](../decisions/0145-same-pool-block-cloned-clones.md),
[ADR-0149](../decisions/0149-independent-observability.md),
[ADR-0159](../decisions/0159-remove-legacy-compatibility.md),
[ADR-0161](../decisions/0161-monospace-web-presentation.md),
[ADR-0163](../decisions/0163-bounded-standby-refill-and-capacity-damping.md).
