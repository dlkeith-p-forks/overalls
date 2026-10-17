# Integrated emulated guest transport

The NixOS TCG host contains real ZFS, Lilly, the guest control server, and its
QEMU/vhost-vsock processes. Lilly reaches the control server through a local
Unix socket. Guest overlays reside in `/pool/guest-emulator` on the verified
ZFS dataset. No Unix socket is transported through the outer 9p mount.

`GuestChannels` uses a freshly verified exact running boot to derive the local
`/run/overalls-tcg/<placement-prefix>/v.sock` path. Lilly's ordinary terminal
client performs the actual port-1075 CONNECT handshake and challenge HMAC.
Its host stream still authenticates to Marshall and enforces ordinary current
execution and terminal authority. The adapter omits serial-log disclosure.
This implementation is present; an actual integrated terminal journey has not
yet been recorded.

The separately selectable `privateGuest` image enables the production private
guest services with a public inert bootstrap certificate. Its signing key was
discarded when the fixture was created. The certificate grants no runtime
service authority: the host must deliver its actual current public CA set via
the ordinary boot-bound trust protocol before private SSH-backed readiness.
The baseline host image remains separate from this variant.

The inner host's real `lilly.slice` enforces a two-core CPU quota and a 5 GiB
memory ceiling. Lilly and the guest emulator share that slice, including the
emulator's QEMU descendants. The health observer reads the actual controller
files; missing controllers produce unavailable state with a closed diagnostic
code. This is emulated-host accounting, not native Firecracker confinement.

Host preparation enables real IPv4 forwarding and requires `lz4` compression
on both the owned zpool root and its Lilly dataset, matching production startup
checks. A retained root policy repair happens only during preparation after
the pool, dataset and fixed member identities match. Health sampling only
checks that policy. A separate `diagnostics.json` publishes closed systemd
states and these two kernel/storage prerequisites without journal messages or
credentials; these diagnostics do not establish execution readiness.

The operator reaches the inner read-only witness socket through
`witness_worker.py` on the private 9p share. Requests and replies carry one UUID
envelope in `witness_requests/` and `witness_results/`. The worker accepts only
image identity, guest witness, terminal witness, and terminal input-stall
observations, with bounded frames and the fixed inner witness socket. The
operator retains its current-authority and response validation. A selected
spool transport never falls back to an unrelated outer socket.

The outer Audi connector cannot dial an inner-host Unix socket. The separately
selectable `privateHostImage` instead contains real inner Audi, Ziggy and Galileo
roles, with service UIDs 991, 992 and 993. Private PKI is generated and retained
inside the host; host-bound satellite credentials arrive through the private
share. Audi resolves the actual guest peer through Lilly's local
`/run/lilly-ingress/private.sock`. The variant built and booted with real ZFS,
cgroup measurements and runtime PKI generation; enrollment and private-role
credentials remain pending. Guest trust, SSH roster delivery and a terminal
journey are not yet recorded.
Ordinary external ingress remains unavailable.

Inner Ziggy's fixed loopback provider uses the existing origin fixture and
durable request receipts. Its listener is bound only to `127.0.0.1:8080`, checks
the exact Host header and a private synthetic provider credential, and forwards
only the fixed OpenAI fixture routes. A real local HTTP test verifies discovery
and refused credentials; this does not establish integrated Ziggy control or
guest authorization. Synthetic Galileo HTTPS origins still need their separate
runtime trust bundle before integration effects can be claimed.

## Exact QEMU fault

Only the trusted operator and inner host share the private fault volume. It is
separate from read-only observations and is not mounted in the workload.
The operator checks current fixture ownership and physical identity before
atomically publishing a request into `requests/<request_id>.json`:

```json
{"version":1,"operation":"crash_guest","request_id":"11111111-1111-4111-8111-111111111111","placement_id":"22222222-2222-4222-8222-222222222222","execution_epoch":1,"generation":1,"qemu_pid":123,"qemu_start_ticks":456}
```

`fault_worker.py` claims a request durably before acting. Under the runner's
placement lock it matches the entire retained placement/generation/process
identity. `crash.py` opens a pidfd, rechecks the live start tick and pinned
executable, sends SIGKILL through that descriptor, and waits up to five seconds
for kernel exit readiness on the same descriptor. It never signals a replacement
numeric PID. A retained uncertain claim after worker restart returns unavailable
and is never retried.

Receipts in `receipts/<request_id>.json` contain exactly `version`, `request_id`,
`placement_id`, `execution_epoch`, `generation`, `qemu_pid`, `qemu_start_ticks`,
`state`, `sent_monotonic_ns`, and `exited_monotonic_ns`. State is `exited` only
after positive kernel exit evidence; unavailable receipts have null timestamps.
Monotonic timestamps belong to the inner host and cannot be compared directly
with outer-host time. Repeated request IDs retain the original receipt.

The actuator kills QEMU only. Backend retirement, Lilly's crashed outcome,
Marshall's crash budget, and subsequent guest boot require their own observed
reconciliation. An exit receipt alone does not establish recovery or release
disk reservations.

## Local verification

Six tests execute real expendable child processes to cover exact pidfd exit,
wrong start tick and executable refusals, stale boot tuple refusal, stable receipt
replay, and refusal to reapply an uncertain recovered claim. They pass with the
pinned Python 3.13 interpreter. Three additional tests exercise the read-only
witness allowlist, actual local-socket spool delivery, and unavailable transport.
Ruff formatting/lint and scoped ty checking pass.
These are process and local-filesystem checks; actual QEMU, 9p persistence,
integrated guest boot/recovery, and native isolation remain separate evidence.
