# Nix-built Ubuntu guest review

## Scope and impact

ADR-0068 adds Ubuntu distribution selection and declarative packages, files and
public CA inputs. It preserves ADR-0011's artifact/console boundary, ADR-0014's
image admission, ADR-0037's relocation readiness and the dedicated NixOS Inception
image. No wire protocol or database fields change. Packages install offline in a
Nix build VM after signed snapshot resolution and hash-pinned fetching.

The final branch incorporates current main's ADR-0064 Customer isolation and
private-service configuration. Deployment Ubuntu images inherit the explicit
platform public roots and split `.internal` DNS. Profile authorization and egress
remain host/control-plane responsibilities. Public certificates are build inputs;
private keys and runtime credentials are not.

## Findings and resolutions

- **Reproducibility:** APT and ldconfig caches initially changed rootfs bytes.
  Removing those generated caches and normalizing ext4 metadata produced identical
  standard and customized rebuilds.
- **Offline completeness:** Matching request metadata alone did not guarantee an
  independent requested package was installed. Assembly now passes explicit
  requested names as well as local archives to offline APT. Real negative builds
  verify refusal for a missing requested package and a missing dependency.
- **DNS:** Installing systemd-resolved creates a resolver symlink. The image now
  removes it before writing the standard public resolver configuration. Private
  variants enable resolved and bind readiness to successful split-DNS setup.
- **Integration:** An existing relocation fixture assumed NixOS executable paths.
  It now uses the guest's executable search path on both distributions.
- **Fleet preflight:** The clone fixture required 3.5 idle CPU cores for a
  two-vCPU source and timed out before reaching admission. Its preflight now
  derives the threshold from the real VM shape. Production CPU/RAM/disk admission,
  cross-host placement and retained-data assertions remain unchanged.
- **Authority:** The catalog stages and registers the same image list and derives
  the unchanged NixOS default through the shared manifest validator. Existing
  Ash authorization, idempotency and admission own image selection. Both Overalls
  and the newly added Dungarees worker consume the shared deployment image list.

## Verification

Completed on x86-64 Linux with KVM:

- `ubuntu-guest-unit`: seven unit/Hypothesis tests plus Nix input assertions.
  Generated cases exercise actual network/readiness parsing and effect-free
  rejection, with up to 250 examples per property.
- `ubuntu-build-boundaries`: actual isolated APT failures for missing packages
  and dependencies; unrelated build failures cannot satisfy these checks.
- Standard and customized rootfs rebuild comparisons; deployed platform-root
  variant assembly. Both worker configurations evaluate to identical image paths
  and the control-plane default remains the NixOS manifest ID.
- Marshall `mix precommit`: 719 passing cases (64 properties, 655 tests), two
  environment-specific exclusions; compiler, contract checks and Dialyzer pass
  with zero Dialyzer errors or skipped warnings.
- Protocol image-manifest tests: three passing cases, including one property.
- ADR/link and code-contract syntax/discovery checks pass. Semantic review traced
  the shared networking callers, artifact consumers, lock assembly and deployment
  list; structural checks alone are not runtime evidence.

- `ubuntu-guest`: the final customized image passes real Firecracker boot,
  package/file/CA and private-DNS setup, persistence through host loss, independent
  disks, placement-bound readiness, cancellation cleanup, pressure, resize,
  separate data disks and independent cloning. The final merged-source run passed
  in 1,640 seconds.
- `zfs-guest`: the same native lifecycle regression passes for NixOS after the
  shared network helper change; the final merged-source run passed in 1,500 seconds.

Full Ubuntu fleet relocation acceptance remains open at repository delivery.
Earlier runs passed browser/API provisioning, cloning and network probes, but
did not complete the relocation suite. Subsequent merged runs stopped at the
overstrict clone CPU preflight described above. The corrected fleet rerun is
still running; no complete fleet pass is claimed. Repository delivery retains
this explicit verification gap.

The final native-test derivations remain identical after integrating main’s
remote-builder changes. Both complete worker system configurations evaluated
successfully again on the final merged tree.

## Acceptance limits

These are isolated NixOS-hosted Firecracker tests, not physical multi-host,
production deployment, throughput or inference-service acceptance. The fleet
fixture now includes main’s mandatory Ziggy role with issued control credentials
and an isolated provider catalog; this does not establish inference acceptance.
Ubuntu fleet scope includes running/stopped moves,
return moves, cancellation and cleanup, plus browser/API provisioning and cloning.
The separate relocation failure matrix and whole-node update acceptance are
outside this image check.
No production activation was performed.

Full flake evaluation remains outside these scoped results. Inception evaluation
reported a missing `services.ziggy.secretsFile` at `nodes.outer`; main has since
adapted the shared fleet fixture, while that separate Inception gap remains.
