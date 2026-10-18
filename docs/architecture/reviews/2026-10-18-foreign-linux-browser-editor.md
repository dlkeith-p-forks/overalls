# Foreign Linux browser editor (2026-10-18)

## Scope and architecture impact

AlmaLinux displayed “This machine's image does not support the current browser
editor.” The same omission affects Arch. Their Linux agent capability row permits
editor support, but the earlier immutable images contain neither the editor/broker nor
the exact editor descriptor. `Image.editor_capability/2` correctly refuses those
images; the successful seven-family CLI SSH/lifecycle journeys establish no
browser editor acceptance.

The repair applies ADR-0153's package and broker boundary, carried forward by
[ADR-0158](../decisions/0158-durable-guest-identities.md), to the two additional
Linux builders. It adds no Ash domain, deployed host service, protocol version,
authorization grant or native guest capability. The broker remains a guest
service under the existing Lilly TCP 4444 fence. The domain and deployment
inventories retain their existing ownership and placement.

Integration imports trunk through `9e7f6bd3`, preserving ADR-0193's failed-machine
pin refusal, ADR-0195's time-zone feature and the `8fe9786` test-engine update.
The imported clock hook ran before fresh-login checks, conflicting with
ADR-0022 and the existing required-login contracts. Required/security mounts now
install fresh-login checks first; optional/public behavior stays unchanged. A
real persisted-login revocation regression first failed on the imported order.
Merged-source execution is recorded separately from the earlier `cdd323d51`
gates and immutable native fixtures. ADR-0191 and the handbook distinguish the
new pin from historical NIF and dependency-snapshot acceptance.

The final review also restores ADR-0195's browser-only disclosure boundary for
sharing/team SSH responses and completes UTC provenance for thread activity and
operational expirations. The time-zone review records those integration findings.
The combined generated trace schema now includes the reviewed Audi proxy event,
finite phases and response-state/count fields; its prior mismatch was not a
passing schema result. No raw request/header/error value or payload is added.

## Implementation and refusal boundaries

The [shared builder](../../../nix/domains/artifacts/guest/foreign-linux.nix)
accepts the pinned editor and broker together, copies their complete closure,
registers it offline and retains package/configuration/unit GC roots. The
editor's existing direnv integration also receives its pinned executable, PATH
link and GC root; this adds no project language toolchain. The
version-4 manifest binds the exact protocol, source commit and release. Editor
images require at least 2 GiB RAM and 2 GiB writable disk headroom beyond the
immutable rootfs. Neither a distribution label nor package presence grants
editor authority.

The guest broker uses the distribution's systemd, current roster authorizer and
private trust bundle. Network, private DNS and roster ordering precede broker
startup; readiness does not depend on editor startup. The broker still verifies
the exact current boot, gateway, account and release before starting a worker
under its reconciled personal UID. Images without private roots do not enable
the listener. The PAM helper, public-key-only SSH policy, nosuid mounts and
readiness contracts retain their existing boundaries.

Optional build-time files are restricted to fresh canonical `/opt` destinations,
closed source/mode values and ordinary regular sources. Existing destinations,
symlink parents and protected platform paths refuse. This supplies disposable
native browser-policy fixtures without a runtime file-write grant.

Retained Arch and Alma disks are not upgraded by host activation. Their old
manifests must keep refusing the editor; new machines must use the rebuilt
images. FreeBSD, OmniOS and Windows editor capabilities remain disabled.

## Verification

The final direnv-inclusive `foreign-linux-guest-evaluation` and
`foreign-linux-guest-filesystem` checks passed in 109 seconds with remote
builders disabled. Their immutable outputs are
`/nix/store/y4yxls9wvdlk6q6hbb84hgsgv70linrj-foreign-linux-guest-evaluation` and
`/nix/store/w3sp379xffdh3q4zb0sqprghzslw1h11-foreign-linux-guest-filesystem`.
Build log `1792329170684-1385769-0.jsonl` has SHA-256
`cbf46675ea16f65b58eb1b062ea4dce9242a8f425a3f9a80c0f148bc31d84f16`.
The checks compare actual editor/broker/configuration/service bytes, root
custody, activation and GC links, complete registered paths/hashes/narSizes/
references, closure presence and RAM/disk minima. Evaluation separately refuses
incomplete package pairs, insufficient RAM and unsafe customization values.

The unchanged kernel and initrd remain `99889786…` and `15f9240e…`. Both images
bind editor protocol 1, source `2a59476c9bfcb90b3ddc372c36762471b7dfad1c` and release
`5a7e35482a5aff16090e1f6e83460ff0a45f0f1a1d692a888e68f5c5ebbd00fe`.
Both retain 2 GiB RAM and an 8 GiB minimum disk. Arch's 2,864,324,608-byte rootfs
has SHA-256 `568d25962a401171d0671029663a1bad888e30c254e92656925fa8f72787bdfd`;
Alma's 3,129,978,880-byte rootfs has SHA-256
`ff6c230a708e184b9080b12e1061f289118d437a6a40bad975c4fa81ab0d4c4b`.
Protocol independently validates the new image IDs as Arch
`sha256:0b3da3e83c596889ce66dd7bd0b2062cdddbf30c204d97a9924bb8bd8fb8be23`
and Alma
`sha256:65e7700b61936ea2541ef3ea91cb1569a32f37c368a95f74f305a63920c2975b`.
The typed custody receipt `/tmp/overalls-foreign-editor-custody-20261018.json`
has SHA-256 `ef40d14efa93970dbf305f0670d78dbc8afa6932d8b36ef661538fd14ae40daf`.
It independently rehashes the six artifact files and manifests, verifies old
boot-file byte continuity, source hashes and exact parser/service bytes, and
records the parser invocation/exit status. Its generator is guarded to pinned
Elixir 1.20.4 and OTP 29.0.6. It grants no guest execution authority.
The exact service passed each pinned distribution's native unit parser
(Arch systemd 262, Alma systemd 257) using local dependency stubs. This is parser
acceptance, not a service boot.

Retained helper-fixed Arch `99fa9876` and Alma `473f9589` fail the new editor
predicate and lack the launcher/service/GC root. The read-only negative receipt
`/tmp/overalls-foreign-editor-old-image-negatives-20261018.json` has SHA-256
`9edd8f7eab28113eacee71cd39f9106c7943a3d3c6076b5e62fbcee46e137a30`.
The existing exact-release/image Hegel property and malformed/absent-descriptor
test passed: **2 passed**, with isolated task PostgreSQL. Log
`/tmp/overalls-foreign-editor-image-capability-isolated.log` has SHA-256
`a84e8ad995e76470b76c67a7f905f4d924916e0621fb7e9bc6b537d477dd4988`.
An initial invocation failed database setup and executed no tests; it contributes
no passing evidence.

The expanded helper passed pinned Ruff format/lint/ty and contract discovery;
log `/tmp/overalls-editor-family-static.log` has SHA-256
`d3670ce1e098901daed971bbdb779483c31191d6a88c9fb2d0ac6b2a942fe2f4`.
An independent source/contract review found no blockers in the inspected diff
against `7c5f191c9`; its nine-path diff SHA-256 is
`d6ec35204c636a372675894a983f8291e6fb1a15eb13a484f3048d5b48699d41`.
These results establish neither kernel isolation nor browser runtime acceptance.

The exact Alma full-chain derivation
`/nix/store/5xwyaq2cy9ypfwawfgq1ssppkxy7lp1f-vm-test-run-overalls-vscode-web-almalinux-fleet.drv`
passed all **12 native subtests**: 693.21 seconds of machine execution and
1071 seconds including local-only prerequisite builds. Its immutable output is
`/nix/store/03w3c7zhhqbn7fv2lpbhqslr3n72p1i7-vm-test-run-overalls-vscode-web-almalinux-fleet`.
The ordinary browser provisions the actual Alma image with the default shape,
opens its personal editor/terminal and isolated webview, and checks immutable
policy, extensions, EditorConfig and explicit direnv approval. Live bridges
survive Lilly/hostd restarts; broker restart retains the worker and workspace;
worker loss requires a fresh authorized open. Same-disk stop/start retains
saved files and admits only the new execution. Foreign Origins refuse and
sign-out closes current editor authority.

The receipt `/tmp/overalls-editor-almalinux-fleet-evidence.json` has SHA-256
`60b683862593b7f78c28d52ab5382db9b9977b10ee899d2d7d53460558e511ae`;
its complete driver log has SHA-256
`de289af3737144c14f29d815879b90346cde13bde095d13870c0ab62c927cbdb`.
The isolated Alma fixture is image `90eca504`, with private fixture roots and
immutable `/opt` policy files, not production image `65e7700b`. Its
3,246,698,496-byte rootfs has SHA-256
`2414e19461ef1ae87da129ad2c6449fffbc3aa6ab209f36d5b6fc671efc1f5c6`.
All five recorded builder/driver/helper source hashes and all 110 historical
receipt hashes remain unchanged. This captured derivation predates the later
Marshall HTTP security changes and does not qualify those changes.

The Arch suite is separately captured from merged revision
`cdd323d51c6dd88934ef333eb2dd2cf6a34bee8f`, including ADR-0194's endpoint
headers and actual secure-cookie login. Its exact derivation is
`/nix/store/ci3x702i4dniylyccj91j5zxad5h7wcj-vm-test-run-overalls-vscode-web-arch-fleet.drv`;
the first **8 of 12 subtests passed**, including ordinary provisioning, the
personal editor/terminal/webview, policy and live bridge survival across both
Lilly and hostd restarts. The next broker-restart recovery subtest failed:
initial fresh handoff succeeded, but later folder navigation returned HTTP 502.
Broker and worker health probes remained positive; the account-level Node probe
failed but selects a different Node store path from the actual editor runtime,
so it does not establish a worker runtime failure. The exact cause remains under investigation, and later recovery,
same-disk restart and refusal stages were not reached. The failed build and
immutable driver are retained; this original run supplies no full Arch browser
pass. No CSP
relaxation or forged browser session is used. Functional editor instrumentation
runs on the separately served editor origin.

The failure exposes a diagnostic gap: the HTTP proxy collapses connector,
request/upload and pre-header receive errors into the same 502 response. The
diagnostic correction adds catalogued finite phase/error categories, the actual
editor Node path and bounded guest resource-pressure booleans. A replay must retain
the original 2 GiB default, all stage assertions and deadlines, and the original
failure. These diagnostics change no access, framing or recovery contract under
ADR-0042/0158; they are not evidence that recovery has been repaired.
The original failed-run receipt
`/tmp/overalls-editor-arch-fleet-failed-evidence.json` has SHA-256
`d258a6d99e89f1d4276b75bd1f6867ce5a42e685372b017de85545efe89825ed`.
It binds all ten original source hashes, the exact driver and fixture bytes,
eight completed stages and the failed assertion/502, with exit 1 after
588 seconds. It also rechecks Alma and the frozen seven-family evidence.
The real-handler proxy/privacy checks passed **21/21** with seed `497400`,
including unchanged 502 responses for closed/malformed upstreams and canary
redaction from payloads and inherited metadata. Log
`/tmp/oa-rHmf85al/proxy-diagnostic-focused-v3.log` has SHA-256
`1dbaf8401fff3943c0d14c4b176a6d4b110358af76ed616c4bacec6f7839e25a`.
This proves finite diagnostic behavior, not the cause of the native 502.
The same-image diagnostic replay is captured as
`/nix/store/sgnphysw0d315c9dg4r922fgdcxirzfz-vm-test-run-overalls-vscode-web-arch-fleet.drv`.
Its frozen source ledger has SHA-256
`2855ba04a63ea24bee7e0abe855c8f449dfba31ee38b9127c0bb092328e72607`.
The recursive closure retains the original `b1c8ff76` fixture image and
`2a6f7729…` rootfs, 2 GiB RAM and 8 GiB disk minima.
Arch diagnostic replay passed all **12 native subtests**: 618.2 seconds native
and 951 seconds including local prerequisite builds, exit 0. Receipt
`/tmp/overalls-editor-arch-fleet-diagnostic-evidence.json` has SHA-256
`aa1a30c10765d3920667f407944ce043ce7d4da9bb44422f00217676eb359eeb`;
its closed runtime log has SHA-256
`e7b4813a3fd4ba33acd0be10cb55d56715f40480454d2d91b2260bc8ed1e0d4b`.
Six finite receive/closed events occurred during successful broker and worker
recovery. They do not establish the original 502's cause; its receipt remains
unchanged. Failure-only native memory/OOM/PID and corrected Node probes did not
execute, so their evidence remains static. This passing captured premerge build
does not qualify the later trunk merge or a production browser session.

Both **production** replacement images passed fresh CLI lifecycles in
`/tmp/porsche-20261018-132308`: create/readiness, strict personal-account
`overalls ssh`, stop, independent current-owner stopped checkpoint, restart
the same VM, repeat strict SSH and original owned deletion. The four unchanged
read-only managed-identity/PAM-helper/sudo smokes also passed. Alma fixture
`3d60db8a-944b-40b9-a785-93d76f5f57b3` and Arch fixture
`0cc83b9d-df45-4093-8b84-bc4155721158` are both terminally deleted; no retries or
replacement fixtures were used. The hash-linked summary
`fresh-linux-image-cli-acceptance.json` has SHA-256
`e9e4b1cd10289af94112edd870a5f496682f07dde9bd8bf9215017b5e2176671`.
Sixteen per-stage deployment observations bind exact catalog IDs, the unchanged
other five images and stable, healthy activated/lastHealthy revisions containing
the pushed editor fix `a6ca2782`. The helper mount remains nosuid; these checks
claim the observed root PAM/sudo path, not effective unprivileged helper setuid.
This is no production browser journey. The earlier seven-family aggregate
remains frozen at `c77e3386` with its original image IDs and execution revisions.

The packaging commit `f7a4ef07c` and normal upstream merge `a6ca2782e` were
pushed only to trunk. A subsequent reviewed merge `cdd323d51` preserves the
new HTTP security headers and Hegel exploration changes. It also carries a
test-only connector socket fix: PID-qualified names and explicit unlink errors
prevent concurrent BEAM fixtures from removing one another's listener.
Focused Audi connector/authority tests passed **8/8**, Covenant **10/10** and
forced Dialyzer reported **0 errors**. Full Audi precommit failed **2/213**:
HTTP proxy shutdown reproduced in isolation, and the known Inception timeout.
The original fixture replied and closed before consuming Mint's streamed empty
GET terminator. A narrow test-only correction now consumes bounded headers and
the exact empty chunk before replying, preserving the existing payload, header,
stream, generator and timeout assertions. The original failing case now passes
with seed `497400`: **1 passed, 8 excluded**. The exact original Mint error was
not retained, so the fixture error does not establish its precise reset cause.
That fixture-framing correction changes no production proxy code. The original full-gate log
`/tmp/oa-rHmf85al/precommit.log` has SHA-256
`cdc3f3db1796b0a3efb20587c70875ceb7cbcd1c799e2554ef9b74484c9291c2`.
The corrected isolated log has SHA-256
`88b9b732e7e26c3606deae2d7f6042557d1fa8dc9c8fa81e9b558d7919f8910b`.
A later full Audi gate stopped at an imported property-test syntax error before
executing tests. The narrow correction removes a dangling comma while retaining
the existing CI profile, exploration and assertions. The final Audi gate exited
2: **211 of 214 passed**, seed `342853`, with four test cases in parallel and
717.6 seconds total. The known Inception case and generated live-stream guard
history each hit 60 seconds; the restored-default fresh-role-boot property hit
its 600-second aggregate budget while starting a child VM. No assertion failure
establishes a guard or invalid-boot product defect. Exploration and deadlines
remain unchanged while their fixture cost is reviewed. Covenant **10/10** and
forced Dialyzer with **zero errors/skips** passed. The full log has SHA-256
`20915dc43f402f43483cddc083f2557c831763012818bdb85bd90ff3ba1d965c`.
No full Audi gate pass is claimed.
The merged `8fe9786` pin still runs 100 outer cases. The stream-guard property
therefore retains all generated actions, TTLs and per-action 1/2-second refusal
bounds while giving the complete property a finite 300-second aggregate budget.
Its complete module passed **9/9** in 105.3 seconds, seed `342853`, directly
exceeding the old 60-second budget without weakening a closure oracle. The
42-mutation boot property still schedules 4,200 fresh OTP starts if completed;
its 600-second limit and all assertions remain unchanged. Its old 126-start
comment is corrected. A clean forced source build loaded the new pin's actual
NIF with SHA-256
`4b82b70e1562e02ad0751d5b31df1ef9cb5b024d6a26c2726c9d94d43a09b90d`,
without an override; this differs from the older pin's library. Full merged
consumer gates remain separate. All eight current ordinary-production
fixed-output dependencies were subsequently realized from existing caches.
Every embedded lock equals the immutable evaluated source and current checkout;
every independently computed recursive NAR hash equals configuration. Qualified
receipt `/tmp/overalls-8fe-fod-custody.6EMduL/receipt-qualified.json` has SHA-256
`9ab22b9dd67c43eb37c66d38c79defb5093495500718b83baaeab688c6bdc09b`.
Its completed merge base is `0de23e24d`; it explicitly corrects earlier
in-progress-merge wording without altering the original capture. It establishes
cached ordinary-production dependency custody, not fresh fetch/reproducibility,
releases, native NIF execution, harness variants or Cargo.

The merged protocol and Lilly precommit gates passed **303** and **610** tests,
respectively, including Covenant **14/14** and **15/15** and forced Dialyzer
with zero errors or skips. Their logs
`/tmp/overalls-editor-merged-protocol-precommit.log` and
`/tmp/overalls-editor-merged-lilly-precommit.log` have SHA-256
`a4a6c02376b2130dacb2d2c51f13dc5e67ecf2e56bcaa6d21f465fdf00189902`
and `43ca4dac374198c01e0507c903d38769d987b483e8af5d376dbc18dffcceec39`.
These are BEAM consumer gates at the imported dependency pin; neither reruns
the captured native browser tests or production sign-in.

The current-pin Porsche precommit exited 2: **99/100 passed**, seed `966054`,
four test cases in parallel and 287.3 seconds of tests. Its fresh-process
invalid-boot property exhausted the unchanged 240-second aggregate budget;
no assertion failure establishes an invalid-configuration product defect.
Covenant **4/4** and forced Dialyzer with zero errors/skips passed. Two
formatting-only failures were corrected first: the new failed-pin hint's
line wrapping and the Hegel certificate property's indentation. The complete
post-format gate log `/tmp/overalls-editor-merged-porsche-precommit-v2.log`
has SHA-256
`ba20a03bf29887ca0fdc69eb3bc73524df29691c45070215cf368c54ac91b1be`.

The current-pin Audi precommit also exited 2: **212/214 passed**, seed `835548`,
eight test cases in parallel and 741.8 seconds of tests. StreamGuard passed
with all default histories and per-action deadlines intact. The remaining
failures were the known Inception 60-second timeout and the unchanged
fresh-process invalid-boot 600-second budget. Covenant **10/10** and forced
Dialyzer reported zero errors/skips. Receipt
`/tmp/oa-rHmf85al/audi-merged-8fe-precommit/receipt.json` has SHA-256
`9c8543d85ff19b6fb9919bb83cdd53587ccb3c0bfbc7baddf216b203f96c3aad`;
its full log has SHA-256
`a9b66b132be44a89cda5d8cdb3dd1f5ed277ed021feb96a804b116654fce1fd4`.
All Audi sources, locks and actual native engine remained frozen. Root-owned
review documents and the generated diagnostic schema changed during the run;
the final schema's focused execution is separate from this full-suite result.
No complete passing Audi or Porsche gate is claimed.

The complete merged Marshall gate passed **1,757 tests with 4 exclusions**,
Monospace and forced Dialyzer with zero errors. Its focused post-correction
run passed **63 tests**, contracts, logging, workspace and Monospace checks,
and forced Dialyzer with zero errors. These checks cover the final CLI
projection and timestamp corrections; they do not rerun native browser or
production sign-in journeys.

An initial Marshall full gate was interrupted after concurrent test fixtures
exhausted its isolated PostgreSQL connection budget. The bounded replacement
passed: **1,725 tests passed, 4 excluded**, Covenant **29/29**, terminal **36/36**,
workspace/privacy **9/9**, Monospace checks and forced Dialyzer with **zero errors**.
Log `/tmp/overalls-editor-merge-ui-precommit-bounded.log` has SHA-256
`bd184f4d97f25b460bbb3ef3e0de32cc84ae3295bd2ef3609ed359c6dd6fbe59`.
Receipt `/tmp/overalls-editor-merge-ui-precommit-bounded.json` has SHA-256
`10188398eee878e361146463409202d9ed8e6c398baeb61c39a67b02b5591efb`.
Its unchanged Marshall production/test logic is based on `cdd323d51`; dirty
handbook content and later Audi edits are distinguished from that source scope.

The scoped current strict-CSP Monospace probe also passed **61 screenshots**:
the original machine/workspace route loops in both themes and viewports,
drawer/pin/control assertions and final external-request, CSP-violation and
browser-error checks. Its actual dirty Audi/HLDD/asset inputs stayed stable.
Receipt `/tmp/overalls-editor-merge-ui-csp.zo2h1xkr/result.json` has SHA-256
`3be28039a714e8a45d8a5bc1abb34808b6908baa1c5bab9ac654832e9a7ef1f4`.
The broader thread/admin/public/draft/reduced-motion tail was outside this
probe; its earlier full-probe failure remains separate. The owned fixture,
listener, private browser context and database connections were cleaned up.
Production recurring probe names and credentials are unchanged.

## Remaining gaps

Production browser sign-in and recurring history require real operator session
fixtures; none is fabricated by this work. Physical isolation, broader native
capabilities and the remaining custom-kernel plan retain their existing partial
status. ADR-0158 and ADR-0190 are not marked implemented by image packaging.
