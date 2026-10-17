# Inception completion audit

## Scope and architecture impact

This review audits the Inception implementation beginning at `origin/main` at `20b2f0a`
and reconciles the later `2a998bf8` Lyra guest change
against ADR-0033, ADR-0054, ADR-0072, ADR-0085 and ADR-0098. The image corrections keep
ADR-0085's existing offline, instance-specific guest trust design and change no
domain boundary, protocol, authority, persistence format, network policy or
runtime secret flow. The fleet profile change implements ADR-0033's accepted
nested-builder requirement by enabling and advertising nested KVM on base and
enrolled fleet hosts. ADR-0085 remains **partial**; ADR-0054 remains superseded.

The audit used a separate worktree and did not deploy, use production DNS or
SMTP credentials, or claim public acceptance from evaluation and component
tests.

## Findings

### High — nested image cache omitted the evaluator sources

The native `kittens-inception` driver passed nested-KVM eligibility, proof
tamper rejection, outer host enrollment, two DNS replica enrollment, gateway
startup and launch of the first managed Firecracker VM. The VM did not return
its boot-bound core readiness response. At the production ten-minute deadline,
Lilly stopped Firecracker and committed `execution_failed`; the driver therefore
did not reach the second environment or later public and lifecycle phases.

A bounded rerun snapshot identified the first failing inner unit:
`inception-image.service`. Identity, credentials, private PKI, storage,
PostgreSQL, database setup, the environment and migrations were active. The
runtime recipe imports the pinned guest source and pinned Nixpkgs source, but
the cache filtered every path whose name matched `source`. The guest therefore
could not evaluate its offline image recipe. After restoring those inputs, the
native unit still failed because it invoked `nix-build --offline`; the pinned
legacy command rejects `--offline`. The unit now uses the supported
`nix build --offline --file` interface. The cache retains both required trees
explicitly, and the evaluation check executes the same offline CLI form.

The fixture also waited for its generic 25-minute lifecycle deadline after a
terminal failed outcome and did not replay its already bounded core diagnostic
at the failing assertion. It now fails immediately on the terminal `failed`
state and prints only fixed active/failed predicates. Increasing the fixture
timeout would violate the production socket and executor bounds and would
conceal failures.

A second native run with the corrected cache and command again reached the first
managed Firecracker VM before failing the production ten-minute deadline. Fixed
predicates proved that its root filesystem was resized, had at least 4 GB free,
had `nix build` enabled and contained the public root, image cache, pinned guest
source and pinned Nixpkgs source. The rebuilt manifest was absent. The journal
matched none of the fixed disabled-feature, missing-path or no-space categories.
The unit now reduces build output to a closed failure category and deletes the
raw runtime log, allowing further native runs to identify defects without
exposing arbitrary build output. The next native run proved the rebuilt manifest
present and `inception-image.service` active.

### High — Inception ingress and guest backup flush bound the same vsock port

The corrected image reached active PostgreSQL, migration, enrollment and nested
image services, but the Inception namespace remained absent. A fixed-predicate
probe found `inception-ingress.service` neither active nor failed during its
restart cycle. Source inspection established the collision: the shared guest
starts `lilly-flush` on vsock port 1026 and the Inception module also bound
port 1026. Thus the parent could not deliver the namespace and the ten-minute
boot readiness deadline failed. This is an implementation defect, not a change
to the accepted separate-channel rationale of ADR-0085. Inception ingress now
uses dedicated port 1028 in the guest, protocol and Lilly poller; a cross-module
test checks separation from the inherited flush listener.

The next native run passed the inherited flush, dedicated ingress and namespace
checks, confirming that this collision was resolved in a real guest.

### High — core readiness timed out before the bounded image rebuild

The native run with the dedicated port reached an active namespace, private PKI,
storage, PostgreSQL, environment and migrations. At the seven-minute diagnostic
sample, the image service was still starting, with no rebuilt manifest or
classified build failure. Lilly's ten-minute core-readiness deadline stopped
the first managed VM before the image service's separate thirty-minute build
bound. Enrollment and Marshall/Lilly startup consequently never occurred.
The build may still fail later; this run establishes a deadline mismatch, not a
successful offline rebuild.

Lilly first permitted a bounded twenty-minute readiness wait only for Inception
execution. A full native rerun and an independent direct guest benchmark both
exhausted that window while `inception-image.service` was still starting and
had no rebuilt manifest or classified failure. The direct guest continued
running after its readiness waiter exited, confirming that the earlier deadline
fenced an active rebuild. The shared socket helper and Inception executor now
allow forty minutes, while SMTP delivery keeps its ten-minute cap and ordinary
guests retain their two-minute default. The native fixture matches the new
production bound and samples fixed diagnostics at twenty-eight minutes. A full
native run must still demonstrate that the image rebuild and core readiness
finish within that window; the separate thirty-minute image-unit deadline may
also require adjustment if its build does not complete.

### Medium — new Lyra guest input was omitted from the offline nested recipe

After rebasing onto `2a998bf8`, pure evaluation of the native driver failed
because the shared guest constructor now requires `lyraLinux`, while the nested
offline image recipe passed only `pkgs` and `terminald`. The recipe and seed now
use the same pinned Lyra input, and the cache retains it explicitly. The pure
`inception-image-builder` check passes with that input.

The first full image build then exceeded the historical 32 GiB rootfs artifact
limit. The cache filter missed a seed output named exactly `ext4-fs.img` and
retained Lyra's Rust and Zig build tools. Those outputs are not needed when the
nested image is rebuilt from the already built CLI and recipe. The filter now
drops them while retaining their derivation descriptions and the CLI output.
The builder check asserts these outputs are absent. The corrected full image
built with a 32,245,628,928-byte rootfs, within its declared minimum disk and
the current 128 GiB protocol bound. ADR-0098 records the user-authorized
artifact limit increase; it preserves finite descriptors and minimum disk fit.

### Medium — fleet hosts did not advertise their nested-KVM capability

The shared host profile already loaded `kvm-intel` and `kvm-amd` and enabled
nesting for both vendors. Remote-builder declarations required `nested-kvm` for
Overalls and Dungarees, but the hosts' Nix daemons did not advertise the feature,
so required suites could remain unschedulable despite a capable kernel.

The shared profile now advertises `nested-kvm`; base storage configurations and
enrolled hosts assert the setting and vendor module options. The existing
remote-builder evaluation continues to cover both fleets. Advertisement is
scheduler metadata, not runtime proof, so native suites still require and test a
usable `/dev/kvm` inside the test machine. The current exe.dev VM lacks the
feature in its daemon metadata even though direct driver execution has working
nested KVM; the flake does not globally claim the feature for arbitrary hosts.

### Medium — image-builder check required impure top-level evaluation

The `inception-image-builder` check failed in ordinary pure flake evaluation
with `builtins.storePath is not allowed in pure evaluation mode`. The builder
generated a recipe containing literal store paths and then imported that text
again to construct its cache seed. Re-evaluation discarded the derivation string
contexts and treated those paths as unrestricted store lookups.

This was an implementation defect in the build/check path. The builder now
constructs the seed directly from the pinned guest source and supplied packages,
preserving derivation contexts. The exported recipe is unchanged and remains the
artifact used for the offline instance-specific rebuild. Pure evaluation now
passes, as do the runtime and proof-broker checks.

### High — accepted public scenarios still lack native acceptance

The current native driver has executable coverage for proof eligibility, two
environment creation, real DNS-01/control TLS, public reserved-path refusal,
independent private services, nested guest lifecycle, sibling survival, restart
retention and paired disk deletion. Because the first environment failed, none
of the later phases ran in this audit.

The driver now contains independent browser authentication and WebSocket checks,
but they have not passed in a native run. It still lacks real three-layer SSH
through both Firecracker environments,
active descendant stream closure after ancestor expiry/revocation, or a native
cross-environment source-spoof attempt. These are documented unimplemented
requirements. Component and generated-profile tests are useful evidence but do
not satisfy ADR-0085's native acceptance requirement.

## Verification performed

- Protocol Inception/layout/connect tests: 29 passed.
- Lilly named Inception tests: 9 passed.
- Lilly ingress tests: 12 passed with the pinned host-tool path.
- Marshall Inception tests: 12 passed against an isolated PostgreSQL instance.
- `inception-runtime`: passed, including 76 Python cases.
- `inception-proof-broker`: passed.
- `inception-image-builder`: passed in pure flake evaluation after the fix.
- The exact runtime image command passed against an isolated local store
  populated only from the retained cache closure.
- Native `kittens-inception` driver: repeated failures after the first managed
  VM missed ten- and twenty-minute core-readiness deadlines. The dedicated
  ingress port and namespace passed fixed guest predicates in the latter runs;
  the instance-specific image rebuild remained unfinished. A separate direct
  guest benchmark reproduced the twenty-minute wait failure while keeping
  Firecracker alive for the image-unit deadline. Forty-minute readiness and
  the browser fixture have not passed a full native run.
- Base storage, enrolled-host and Overalls/Dungarees remote-builder evaluation
  checks passed with the shared nested-KVM advertisement and vendor settings.
- Code-contract discovery and repository contract formatting: passed.

These results establish the corrected pure build path and reproduce the native
runtime blocker. They do not establish public readiness or production readiness.

## Follow-up work

Complete the direct image benchmark and a full native driver run with the
forty-minute bound. After first-environment readiness passes, validate the
browser/WebSocket fixture and add real nested SSH, active ancestor revocation
and source-spoof scenarios. Keep ADR-0085 partial
until those native checks pass with two simultaneous environments.
