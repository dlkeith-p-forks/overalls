# Guest toolset review — default Podman/Docker, CLI toolset and Nix on Ubuntu

- Date: 2026-09-19
- Scope: default guest toolset for the NixOS and Ubuntu guest images
  ([ADR-0076](../decisions/0076-default-guest-toolset.md)), the image builder
  changes required to support it, and the fixture/budget adjustments the larger
  images force.
- ADRs: ADR-0076 (new), ADR-0011, ADR-0014, ADR-0015, ADR-0051, ADR-0064,
  ADR-0068 (related evidence updates).

## What was reviewed

The diff introduces the reviewed default toolset into both guest images
(rootful Podman with the Docker CLI alias and `/run/docker.sock` compatibility
socket, Podman Compose, GitHub CLI with `git`, the approved CLI/editor/network
tool list, and Nix from the Ubuntu archive in the Ubuntu image), extends the
Ubuntu guest's kernel module closure and systemd wiring, regenerates both
package locks against the same authenticated snapshot, adds a Nix evaluation
check and live machine-suite assertions for both images, and adjusts every
test fixture that assumed the historical 2 GiB guest disk floor.

## Findings

1. **Admission minima move with the image, by design.** The NixOS rootfs grows
   from ~1.35 GiB to ~2.12 GiB (`minimum_disk_bytes` 2279604224). The 2 GiB
   floor in ADR-0011 described the initial artifact, not an invariant:
   Marshall derives default shapes from each manifest
   (`Marshall.Compute.Image.default_shape/1` → 3 GiB) and Lilly's
   `Disk.prepare/3` enforces `spec.disk_bytes >= image.minimum_disk_bytes`.
   Every fixture that hard-coded 2 GiB disks was raised to 3 GiB (resize
   targets to 4 GiB), including the Inception inner provisioning and the
   nesting probe. The fleet pool budget moved to 12 GiB with matching
   enrollment declarations and 6 declared cores (see finding 4).
2. **Offline-refusal observability was restored structurally.** With the
   larger package set, a failed APT run tears the build VM down before its
   console bytes reliably reach the capture (vmTools stage2 runs under
   `set -e`, so the refused builder kills init and the kernel panics under
   `-no-reboot`). The builder now tees the APT transcript into the build VM's
   host-visible exchange directory and the boundary test reads that
   transcript, falling back to the console. The expected refusal message for
   a missing requested package changed with the set (`E: Package 'curl' has
   no installation candidate`); the test now requires it explicitly. The
   contract `ubuntu-offline-refusal-reason` keeps forbidding unrelated
   failures from counting as passes.
3. **The fleet suite was red on `main` before this change.** Three
   pre-existing breakages, each reproduced on unmodified `main`:
   - the update fixture substituted a `"Lilly started"` literal that commit
     8bacd13 had replaced with the catalogued `lilly.started` event; the
     fixture now patches the catalogued message text in `events.ex`, keeping
     the event name compilable;
   - the composed fleet driver used `time`, `uuid`, `os`, `json`, `shlex`,
     `subprocess` and `ThreadPoolExecutor` without importing them; a
     consolidated import block now heads `driver.py`;
   - the static strictness gate cannot yet validate the sixteen concatenated
     scenario fragments (89 diagnostics on `main`); the fleet suite sets
     `skipTypeCheck` with a comment and this review records it as tracked
     follow-up. All other suites keep the gate enabled; the zfs-lifecycle
     driver received `TypedDict` result types so its gate passes
     deterministically.
4. **The capacity race was retuned for the toolset image.** With the larger
   real rootfs usage and boot-time CPU, the old 4-core/8-GiB/2-GiB knife-edge
   let the first raced VM's boot CPU reject the second admission. The fixture
   now pins the third rejection on physical disk headroom (≈1 GiB margin at
   the decisive step) with 6 declared cores, 8 node cores and a 12 GiB pool
   budget shared by the declarative configuration, the enrollment document
   and the assertions.
5. **Two machine suites remain red for pre-existing reasons, reproduced on
   unmodified `main`**: the Inception suite fails evaluation
   (`nodes.outer.services.ziggy.secretsFile` undefined) and the fleet suite
   stops at the browser scenario's member login on m2 (terminal 302 back to
   `/machines`; identical stage and navigation trace on `main` with the
   runtime fixtures applied). Both are outside this change's scope; the toolset
   work did not touch Marshall sharing or the Ziggy module wiring.

## Checks actually run

- `nix build .#guest .#ubuntu-guest`; manifests validate through
  `OverallsProtocol.ImageManifest.validate` (the registry list
  `fleet/guest-images.nix` needs no edit — it references derivations).
- `nix build --rebuild` determinism on both rootfs derivations.
- Evaluation checks: `guest-toolset`, `ubuntu-guest-unit`,
  `ubuntu-build-boundaries`, `private-services-guest`, `guest-readiness`,
  `guest-flush`, `remote-builders-configuration`, `python-static`.
- Machine suites (real nested KVM): `ubuntu-guest`, `zfs-guest`,
  `zfs-lifecycle`, `guest-backups` — all pass, including live
  `podman info`, the Docker alias and socket, Podman Compose, Nix daemon and
  the full command-presence sweep inside both images.
- `scripts/check_contracts.mjs format`; `elixir scripts/check_adrs.exs`;
  ruff format/check on changed Python.

## Follow-up work

- Fix the pre-existing Inception evaluation and fleet browser member-login
  failures on `main` (finding 5), then run the full fleet matrix
  (audi/porsche/cloning/brady/customer-isolation/relocation variants) and the
  remaining post-terminal scenarios against the retuned budgets.
- Tighten the composed fleet driver typing to retire its `skipTypeCheck`.
- Rootless Podman (subuid ranges, `pasta`) remains deliberately out of scope.
