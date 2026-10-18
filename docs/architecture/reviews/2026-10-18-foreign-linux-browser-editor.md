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
was captured and launched with local builders only. Its evaluated driver is not
a passing execution record. Alma and Arch browser execution and new-image live
CLI acceptance are pending at publication. The existing seven-family
SSH/lifecycle evidence remains tied to its original immutable images and
execution revisions. Production recurring probe names and credentials are not
expanded by the fixture.

## Remaining gaps

Production browser sign-in and recurring history require real operator session
fixtures; none is fabricated by this work. Physical isolation, broader native
capabilities and the remaining custom-kernel plan retain their existing partial
status. ADR-0158 and ADR-0190 are not marked implemented by image packaging.
