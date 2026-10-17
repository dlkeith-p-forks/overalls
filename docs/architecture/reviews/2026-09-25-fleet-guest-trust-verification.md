# Fleet guest trust verification

## Scope and preimplementation assessment

Campaign improvement 011 repairs the shared native fleet fixture and verifies
boot-bound trust on standard NixOS and Ubuntu images. ADR-0113, the remaining
roster requirements of ADR-0115/ADR-0117, and ADR-0050's physical admission policy
carried forward by ADR-0051/ADR-0053 remain unchanged. The integrated candidate
also preserves ADR-0124's certified SSH boot prerequisites. No production protocol,
authority, image defaults, deployment topology or storage contract changes.

Source inspection of the original campaign base confirmed that seven existing
variants selected images without the receiver while Lilly supplied nonempty
required trust roots: `fleet`,
`porsche-fleet`, `cloning-fleet`, `brady-fleet`, `customer-isolation-fleet`,
`relocation-fleet` and `ubuntu-fleet`. Only improvement 006 reproduced this as a
runtime failure (two 120-second trust-delivery attempts). Historical feature
results retain their captured revisions; these seven matrices have not been
rerun by this improvement.

Published main `0cfa6302` subsequently selected empty host roots for its minimal
legacy images, avoiding the original trust-delivery incompatibility. Its unified
SSH CA review still records the generic personal-terminal failure without private
roster services. This improvement supplies those actual services and compatible
images across the same seven feature paths; it does not retain the old mismatch
as a claim about current main.

The fixture supplies the actual Audi CA/DNS/private roster prerequisites
independently of scenario selection, uses compatible primary and alternative
guest images, and preserves every existing feature scenario. A bounded strict
native driver creates both distributions through the real authorized
Marshall domain, inspects durable installed receipts and actual guest trust/
network/SSH ordering, rejects a wrong-boot exchange, and verifies a new receipt on
restart. Guest data and services must remain usable after refusal. Neither
readiness nor trust is bypassed.

The independent oracle compares the journal to current boot identity, the host's
configured public root digest, and guest service state and bundle contents. The
existing lifecycle/digest properties exercise generated retry transitions and
root ordering; their presence is not a new execution record. Required validation includes the
composed strict driver, actual KVM/ZFS run, Marshall precommit, contracts, all-file
prek, ADR/HLDD/generated references and Nix HLDD. Independent physical hosts,
full terminal trust exhaustion and all legacy feature matrices remain outside
this bounded result.

## Execution

The integrated candidate passed the complete NixOS/Ubuntu journey, three usable
NixOS guests and the independent physical-capacity refusal. Earlier rejected
candidates retain their exact scope below.

### Passing integrated native candidate

The immutable candidate
`/nix/store/n99x4zg3czzsbin4lnv13my0k7n7hryn-vm-test-run-overalls-fleet-guest-trust.drv`
captured staged tree `f934b2029f70ed45e0d0a7194927a0e3c0bc6a2c` on application
base `0cfa6302`. Execution started at **18:07:11 UTC on 2026-09-25**, ended at
**18:21:30 UTC**, and returned **exit 0** with output
`/nix/store/bkz839br0csxx0hw5m6np8zvxanyv20f-vm-test-run-overalls-fleet-guest-trust`.
Fleet bootstrap passed in **59.43 seconds** and authenticated storage/service
setup in **129.35 seconds**.

Both integrated distributions completed the trust and restart subtest in 431.70 seconds.
This includes actual ADR-0124 certificate-gated SSH readiness, current durable
boot receipts, positive same-boot delivery, completed wrong-boot refusal with
unchanged installed roots and receipt, bounded exact bundle reconstruction,
unprivileged reads, trust/network/SSH service order, local HTTP and retained data
across new boot UUIDs without replacing placement.

Three usable NixOS guests and the independent physical refusal passed in 231.05 seconds.
The actual pool reported its **16 GiB** quota. Three running guests retained
exactly **`3|16106127360`** disk ownership. The otherwise valid **17 GiB** root
request returned exactly `insufficient_capacity`; total VM count remained four
and the same three disk holds were unchanged. This is sequential physical
admission evidence; it imposes no cap on settled virtual promises.

All nine machines were cleaned in **3.78 seconds**. After completion, the owned
driver and all nine QEMU processes were confirmed absent. No guest terminal
contents or private runtime state are included in this record.

For the same application base, complete Marshall precommit passed **1,038 checks
(99 properties, 939 tests), two excluded**, seed **513859**, in **387.6 seconds**.
Forced Dialyzer passed with **zero errors, skips or unnecessary skips** in
**60.73 seconds** after rebuilding the PLT. The composed native driver passed
strict typing and lint; seven-variant configuration, all-file prek, contracts,
ADRs, HLDD, generated references/views/coverage and Nix HLDD also passed before
native execution. These application results do not record a new
execution of Lilly's lifecycle/digest properties.

After native completion, the branch integrates published main `aaba77ee`.
Its existing gateway `Restart=on-failure` and five-second retry remain unchanged;
startup no longer exhausts a start limit, and Overalls activates the fleet API
relay socket before gateway certificate acquisition. Upstream separately records
native issuer-outage and Audi certificate-loss recovery. No Elixir production
code or guest image changes occur in this delta. The native and complete
application evidence above remains explicitly attached to `0cfa6302`; final
evaluated configuration, composed-driver typing and governance validate the
integration without claiming another native/full-application run.

The integrated code candidate on `aaba77ee`, staged tree
`9a212c08736c1eddb49959e92881d0d531ce6f43`, passed those final checks. Contracts,
122 ADR records, HLDD receipts, generated coverage/views/options, all-file prek
(logging, ruff format, ruff and ty) and diff checks returned success. Nix built:

- HLDD: `/nix/store/8924zi6c7jmyklqv4za84axhqai281gi-overalls-hldd-check`.
- All seven configurations: `/nix/store/ngw2241dg6qnbrx70nhvaw8ccsrkyh16-overalls-fleet-guest-trust-configuration.json`.
- Strict composed driver: `/nix/store/iq96ni6bnb4cv2dirvld6xdh5y7mrily-nixos-test-driver-overalls-fleet-guest-trust`,
  with both type checking and lint passing. Its derivation is
  `/nix/store/88cyvq4ha2nh0dzgwzk3s7459hbdb0fa-nixos-test-driver-overalls-fleet-guest-trust.drv`.

The native helper, driver, fleet/operator/evaluation inputs, application library
sources and guest images are unchanged from the passing native tree. Only this
final evidence record and its reviewed governance receipt follow the integrated
static capture; native and full application provenance remain as stated above.

### Rejected native candidate

The first executed candidate was
`/nix/store/wa76izbbmxzkxzz7wsfa41kfagkc9h1g-vm-test-run-overalls-fleet-guest-trust.drv`,
captured from staged tree `63e93152573a90957d6efd865bce0e71b5239d22` on application
base `5bce9478`. Fleet bootstrap passed in 57.25 seconds and authenticated native
storage/service setup in 140.72 seconds. Ubuntu completed initial and repeated
same-boot probes, stop/start with a new boot UUID and retained data, and three
completed lifecycle operations. The first NixOS seed probe failed after its guest
reached installed/running. All nine machines were cleaned in 3.79 seconds.
There is no passing NixOS or three-guest capacity result from this candidate.

Artifact inspection found that the probe invoked `openssl`, absent from the
selected NixOS system's `sw/bin` and explicit guest toolset; Python and sudo are
present. The old fixed failure message does not identify the failed command.
The corrected probe loads the actual guest CA file through installed Python
`ssl` and compares every expected root's DER with the loaded trust store, retaining
exact bundle comparisons and unprivileged readability. This verifies installed
trust, not a live TLS handshake. A closed stage vocabulary and private success/
failure markers now identify failing checks without exposing guest output.
Timeouts and runtime authority requirements are unchanged. Both distributions
and sequential capacity require a corrected native run before acceptance.

Published main `6f58ef65` is integrated for the corrected candidate. Its resize
selector, image-minimum guard, native helpers and evidence are preserved.

The next candidate,
`/nix/store/8qlic46hd7795qf0ni13d8nhxyrkjrdl-vm-test-run-overalls-fleet-guest-trust.drv`,
captured staged tree `b7c898c49780d3434b7975f7272ecd23686ce15c` on `6f58ef65`.
Bootstrap passed in 68.80 seconds, authenticated setup in 225.88 seconds and
Ubuntu's full journey passed again. NixOS reached installed/running and passed
the positive delivery, completed wrong-boot refusal, unchanged host receipt,
boot identity, service order, unprivileged-read, HTTP and data checks. It failed
at the closed `exact_nixos_bundle` stage; all nine machines were cleaned in
3.80 seconds. This does not establish a bundle-content mismatch or a passing
NixOS journey.

The combined NixOS comparison command contained 4,555 bytes. Its four public
roots were 623, 611, 656 and 1,147 bytes before base64 encoding. An isolated
canonical PTY reproduction accepted the write but delivered only 4,096 bytes,
losing the comparison/completion suffix. The probe had sent each next command
as soon as the previous completion marker arrived, before the shell necessarily
returned to prompt input. The correction assembles the complete expected bundle
through bounded base and per-root commands, then retains the exact byte comparison
before the final positive delivery. Every command including markers must fit
within 3,072 bytes. Separate fixed stages identify base/assembly/comparison errors.
A typed local shell preflight reconstructed the real immutable base plus all four
public roots exactly and rejected a bundle omitting the last root; its maximum
input was 1,822 bytes. This is harness evidence, not native acceptance.

Before the next native capture, published main `7681806b` is integrated. The
account-lifecycle driver selection, typed browser/operator helpers, public user
projection, verification evidence and queued same-email roster issue are
preserved. This integration adds no application authority or policy changes;
the combined application and governance gates are rerun for the final candidate.

The integrated candidate
`/nix/store/clqq5a2dpnicn2ghjbsff808499akcjb-vm-test-run-overalls-fleet-guest-trust.drv`
captured tree `60e491fdeecb27869ece7dbeb65017f5e75dbd16` on `7681806b`. Bootstrap
passed in 73.44 seconds, authenticated setup in 190.19 seconds and Ubuntu's full
journey passed again. NixOS reached installed/running and passed the required
active-service observation, then failed the separate `ssh_ready` marker check.
All nine machines were cleaned in 3.82 seconds. The bounded bundle comparison
was not reached; this candidate does not establish its native success.

The NixOS and Ubuntu roster units explicitly remove `/run/overalls-ssh-ready`
before every refresh and recreate it in `ExecStartPost` after successful sync.
The NixOS timer runs every two seconds; an already active listener remains active
through a refresh. The failed single marker observation cannot distinguish an
in-progress refresh from persistent roster unavailability. The corrected fixture
requires the actual marker, sync `Result=success` and all required active services
within the existing 60-second observation, with unchanged outer deadlines. It
never writes a marker, restarts a service or bypasses authority; persistent
absence still fails. The next candidate established this successful observation.

### Completed trust journey and rejected capacity oracle

The corrected immutable candidate
`/nix/store/ffrpc7yf04lsiph2zj34kzcnn9yy67p5-vm-test-run-overalls-fleet-guest-trust.drv`
captured staged tree `76639a3b72d49208a431cd9011b89a43a0261eb9` on `7681806b`.
Its first attempt, started at 17:18:57 UTC, was interrupted by agent orchestration
when the owning turn yielded. That attempt has no product acceptance result.
The coordinator restarted the exact artifact at 17:23:22 UTC. Bootstrap passed
in 72.72 seconds and authenticated setup in 178.91 seconds.

Both distributions completed the trust and restart subtest in 570.38 seconds.
This includes the bounded exact bundle reconstruction, actual successful roster
readiness, completed wrong-boot refusals, unchanged receipts and installed roots,
unprivileged reads, service order, local HTTP and retained data across new boot
UUIDs. The subsequent control reached three usable NixOS guests on one pool,
exactly `3|16106127360` retained disk ownership and four VMs fleet-wide.
The final 4 GiB-root request was accepted, failing composed driver line 419.
The unchanged-VM assertion following it was not reached. All nine machines were
cleaned in 3.40 seconds, and the coordinator confirmed the owned driver and QEMU
processes were gone. Overall execution failed; these scoped passes do not establish
the entire candidate's acceptance.

The failed expectation conflicted with
[ADR-0050](../decisions/0050-usage-based-overcommit.md), carried forward by
[ADR-0051](../decisions/0051-vm-resizing.md) and
[ADR-0053](../decisions/0053-vm-disk-limit.md). The production
[Budget](../../../marshall/lib/marshall/compute/budget.ex) uses measured physical
headroom minus pending startup/copy/growth holds. Settled virtual promises remain
ownership records and do not cap admission. The legacy logical budget remains an
enrollment compatibility field. Fourth-guest acceptance can therefore be correct;
no production policy change is justified.

The correction preserves the three usable guests and exact ownership assertions.
It reads the actual ZFS quota independently and requires 16 GiB, then uses the same
authorized actor, image, OSS profile and compute shape with a 17 GiB root. The
root alone exceeds the entire quota and remains within the valid 500 GiB maximum.
The shared test operator explicitly allowlists this additional size. It must
report exactly `insufficient_capacity`, leave VM count unchanged, and retain the
same three ownership holds. The oracle does not call production Budget arithmetic.
The subsequent integrated native run recorded above passed this corrected refusal.

### Unified SSH CA integration

Before capturing the next candidate, the branch fast-forwards to published main
`0cfa6302`, containing `09b8a045` and ADR-0124. It preserves the upstream 16 GiB
physical disks/quota and `storage_budget` wiring for every fleet route, the
image-minimum-aware operator default, and the legacy race's real physical
two-pending-slot gate. The earlier 12 GiB Audi storage preservation was correct
for the previously captured bases and is historical after this upstream change.

Every path with actual private services now installs the isolated fixture's SSH
CA signer and configures Marshall issuance, independent of feature selection.
Both immutable guest images retain upstream certificate-before-roster/sshd
ordering. The seven-variant evaluation additionally checks all three signers.
This extends the shared fixture's prerequisites without changing TLS trust or SSH
issuance authority. The passing 570.38-second journey predates this integration;
the combined candidate required new native execution and application gates,
which passed with the exact provenance recorded above.

### Completed refusal oracle

The negative request uses a different valid nonempty root subset and an incorrect
boot challenge. Production `GuestTrust.deliver` collapses transport, receipt and
timeout failures into `trust_unconfirmed` and retries; that sender result cannot
prove the receiver has finished. The native probe instead sends one bounded
length-prefixed request after a successful Firecracker vsock handshake and
requires peer EOF with no response bytes. Timeout, connection reset or any
response bytes fail the probe. The real Rust trustd loop synchronously reads,
validates and installs before dropping that connection, so this EOF precedes
inspection of the final installed guest contents. Exact roots and retained data
are checked before the final valid delivery, which might otherwise repair a bad
installation. Both positive deliveries still use production `GuestTrust.deliver`,
with actual confined boot checks around the exchanges. No receipt or authority
is synthesized. This strengthens verification without changing ADR-0113's
production protocol or accepted authority boundary.

## Shared fixture compatibility

All seven checks retain their previous Nix name and selected feature fragments:

| Check | Preserved feature fragments after shared bootstrap |
| --- | --- |
| `fleet` | storage failures, idempotency, capacity, network, updates, terminal, control-plane/provisioner recovery, lifecycle, staleness and credential revocation |
| `porsche-fleet` | Porsche followed by the complete base fleet matrix |
| `cloning-fleet` | Porsche's clone/relocation journey |
| `brady-fleet` | Brady attribution, cache and restart journey |
| `customer-isolation-fleet` | controlled profile placement, network, updates, provisioner and Customer recovery |
| `relocation-fleet` | relocation and relocation failure matrix |
| `ubuntu-fleet` | Porsche followed by Ubuntu relocation |

The `audi` argument still selects names, feature fragments and Audi update
specializations. The composed `audi_enabled` value describes actual shared
services and selects the transfer endpoint port. The transfer port is 2223,
with administrative SSH on 2222 and Audi on 22. Existing explicit scenario sizes
remain unchanged. The operator retains the upstream registered-image minimum
default, adding only the explicit 17 GiB refusal shape. Browser/Porsche defaults
also continue using the registered image manifest.

The first built candidate's trusted NixOS manifest at
`/nix/store/03whj0x446v01pf2sa8l0qwlbwksyl30-lilly-nixos-x86_64`
requires 3,725,295,616 bytes, above the old 3 GiB fixture default. Earlier
candidates used the helper's 4 GiB trusted-image default; the integrated operator
now derives omitted sizes from the current registered manifest.
The base/profile matrices retain their three guests per host and exact capacity
assertions. Their real mirrored storage fixture disks and matching enrollment
descriptor retain upstream's 16 GiB setting, preserving the 512 MiB overhead. This supplies
conservative startup headroom; it is not a logical cap on settled guests or proof
that sequential three-guest admission needs 16 GiB. The existing concurrent
scenario first settles one guest, then races requests with two intended successful
startup holds. Before the upstream manifest-default change, two 4 GiB roots plus
their 1 GiB WorkloadBundles required a conservative 10 GiB of pending headroom,
in addition to the first guest's measured physical use and 512 MiB margin before
new matching materialized credit. The current upstream gate computes the two
pending costs from the actual image manifest and rejects a CPU-only precondition.
The historical race was not rerun here; neither failure with 12 GiB nor complete
acceptance with 16 GiB is claimed for that matrix. All paths retain matching host
and enrollment descriptors because Lilly compares the entire pool descriptor.
No capacity observation is fabricated and no production accounting changes.

The bounded native capacity control sequentially admits three trusted NixOS
guests on one actual pool and checks their running guests and 15 GiB durable
disk ownership. A valid 17 GiB-root request must refuse against the actual 16 GiB
quota without adding a VM or changing that ownership. The positive three-guest
result establishes usable sequential startup with this fixture. It does not
rerun the historical concurrent CPU race or impose a three-guest admission cap.

The maintained `fleet-guest-trust-configuration` check evaluates all seven
variants and asserts their exact names, every full feature fragment in the table,
shared trust bootstrap, absence of the unrelated Audi feature fragment, actual
DNS/private/gateway service enablement, SSH CA signer configuration, root counts,
image identities shared with the bounded dual-distribution fixture and matching
16 GiB enrollment descriptors. The initial equivalent evaluation passed for all seven; its
output was `/tmp/verify011-routes.json`. This is configuration evidence, not
execution of their feature matrices.

Initial Marshall validation on the imported `5bce9478` application source passed
**1,039 checks (97 properties, 942 tests), two excluded**, seed **466651**, in
**440.8 seconds**. This suite exercises the application and shared validators;
it does not execute the new native probe. Initial all-file prek (ruff format,
ruff, ty, logging and HLDD), ADR, generated-reference and contract gates passed.
The later final validation record will identify changes since these checks.

## Final architecture and contract assessment

The final diff changes isolated verification fixtures and evidence. ADR-0113's
boot authority, ADR-0115/ADR-0117's roster readiness, ADR-0124's certificate
prerequisites and ADR-0050/ADR-0051/ADR-0053's physical admission policy are
preserved. No new production API, domain, resource, dependency or deployment
placement is introduced. ADR-0113 remains accepted with partial implementation.

Review covered the seven composed feature routes, image/service/signing inputs,
shared operator admission call, independent physical-quota oracle, real confined
boot checks, completed negative vsock exchange, exact guest bundle inspection,
bounded terminal commands and fixed failure vocabulary. Applicable repository,
Nix-test, handbook and local contracts are consistent within this scope. The
earlier false capacity expectation was corrected in the test; settled ownership
was not turned into a production admission charge.

Installed roots and local HTTP do not prove a live guest TLS handshake, browser
or provider identity, or an end-user SSH certificate-chain journey. Neither
seven evaluated configurations nor this bounded sequential native control proves
the seven full feature suites, the historical concurrent race, terminal trust
retry exhaustion or independent physical-host recovery. Lilly's lifecycle and
digest properties remain present without a new recorded execution here.
