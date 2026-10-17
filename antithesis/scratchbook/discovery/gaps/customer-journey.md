---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
gap: "G9 — composed customer journey"
status: candidate
---

# G9: acknowledged create to retained guest file

The 75-row [catalog](../../property-catalog.md) checks admission identity,
current-boot readiness, durable guest UID, terminal creation/replay and retained
stop/start separately. It has no assertion that joins **one authenticated user,
one create request key, one VM, the current physical boot, the same guest UID and
the bytes of a real guest file** across the full browser journey. This is a
composed customer-visible gap, not evidence that the implementation is defective.
The [fresh assertion scan](../../existing-assertions.md) found no current
Antithesis SDK calls. The [coverage evaluation](../../evaluation/coverage-balance.md)
also finds no primary `Reachable` row and no frozen property-to-template roster.

| Canonical candidate | Priority | Primary type | Additional reach claim | Evidence |
| --- | --- | --- | --- | --- |
| `authenticated-create-to-retained-guest-file` | P0: wrong-user file custody or loss of acknowledged retained data; core usability is P1 | `Always` on every settled, claimed successful journey: the same actor/request key/VM/current boot/GuestAccount UID and exact fsynced guest marker must join, with one allocation for the key | `Reachable` only when a faulted, healed, restarted journey has actually reread the marker through a fresh personal terminal | [Source and oracle](customer-journey/authenticated-create-to-retained-guest-file.md) |

The narrow real path is an authenticated browser `/machines/new` create of an
OSS NixOS guest, followed by `/machines/:id/terminals` and its personal shell.
`MachinesLive` forwards the form's request key and current actor to
`Compute.provision` (`marshall/lib/marshall_web/live/machines_live.ex:115-141`);
admission locks that owner/key and returns the original VM for a matching shape
(`marshall/lib/marshall/compute/admission.ex:34-82`). `TerminalLive` verifies
fresh login and opens the actor's personal session, while `Terminal.Authority`
derives the stored account under current Cedar write permission
(`marshall/lib/marshall_web/live/terminal_live.ex:14-36,60-89`,
`marshall/lib/marshall/terminal/authority.ex:8-31`). The guest shell runs under
the resolved passwd UID/HOME (`nix/domains/artifacts/terminald/src/pty.rs:113-135,186-257`).
No SSH, editor, provider, repository checkout or second guest profile is needed
for this first candidate; those remain independent paths and coverage choices.

The workload owns an immutable synthetic actor/key/shape/marker ledger outside
the SUT. It submits the create through the browser, drops a reply or interrupts
one Marshall/Lilly boundary, then reconciles that key through current authorized
views and a read-only authoritative snapshot before retrying **the same shape and
key**. A timeout remains unknown until reconciled. After exact current boot and
personal terminal authority are observed, a fresh guest shell writes an
unpredictable marker under `/home/u<uid>`, calls `sync -f` on that file, and
reports exit/UID/path. A separate new terminal process rereads the bytes and
`stat` UID after the VM's real stop/start and service recovery, **before any
overwrite**. Compare the reread with the workload's off-guest expected hash;
only then write and fsync a second marker, and optionally repeat a fresh read.
Keep terminal bytes and marker material out of ordinary diagnostics. The
candidate evidence file specifies fail/unknown classification and source seams.

`guest-journey` with `control-core`, a real TCG `guest-vmm`, Marshall A/B, Lilly
and browser terminal ingress is the minimum proposed hosted selection. Keep the
guest overlay and QEMU/backend process identity observable and persistent across
the tested restart. The selected template must actually observe a recovered
fault and full fresh-read witness; a simulated running outcome cannot pass.
`control-core` alone can check request-key/row safety but cannot claim guest
file usability. TCG can establish real guest ext4/terminal bytes for this
configuration, **not** Firecracker/KVM jail, native ZFS GUID, systemd/cgroup or
multi-host storage guarantees. A separate `native-kvm` run over the NixOS and
Ubuntu machine fixtures is needed before assigning those physical claims.

`Always` is the primary invariant because *every claimed success* must be
correct; it is evaluated on each settled success and must be reached by the
selected template. `Reachable` is an explicit non-vacuity target for one full
faulted recovery and fresh guest reread. A `Sometimes(success)` would only prove
that one success happened somewhere in the campaign; it cannot show that every
acknowledged create eventually became usable. Per-request progress remains an
independent workload ledger with a measured post-heal budget and a distinct
pending/inconclusive result until those preconditions are met. Do not turn a
test-template setup failure or one green aggregate exit into this oracle.

## Questions for synthesis

- Which concrete browser driver can retain and resend one hidden create key
  after a lost LiveView reply across Marshall A/B, while distinguishing a
  definite refusal from an unknown commit?
- Can the planned TCG guest template restart the VM while retaining the exact
  overlay and boot witness, and run a second fresh authorized terminal session?
- Which read-only domain/SQL and physical snapshots will expose the key→VM,
  placement/epoch, GuestAccount UID, QEMU process, boot UUID and marker without
  making direct database mutation a workload shortcut?
- What measured TCG boot and post-heal budget supports a bounded progress claim?
  The `Reachable` assertion alone does not answer that question.

No SUT contract, architecture decision or HLDD behavior is changed by these
scratchbook notes. Architecture impact: none. No images, tests, hosted campaign
or native acceptance were run for this gap note.
