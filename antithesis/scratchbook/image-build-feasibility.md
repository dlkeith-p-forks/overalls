---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---
# Fresh pinned image and release build feasibility

Research date: 2026-10-13. Target: `/home/ghuntley/src/kittens-antithesis-reset`.
This is source inspection and offline Nix evaluation only. No images, releases,
guest images or remote runs were built or launched. No deleted harness contents
were read. No credentials were read. No repository files were edited by this task.

## Finding

The repository already supplies eight independently compiled production OTP
releases with locked Nix, Mix and native inputs. It has no Docker/OCI image
exports. A fresh harness can consume those releases, build container roots from
their complete Nix store closures, and add explicit, conditional harness-only
source/instrumentation inputs. Copying just `bin/` or an existing `_build` release
cannot satisfy the runtime closure or source-release contracts.

The production release attrs evaluate offline in the reset worktree. This proves
that their expressions resolve against cached locked inputs; it does not prove
that every required input/output is locally cached or that compilation, image
construction, runtime startup or Antithesis instrumentation will pass.

Physical Lilly acceptance cannot be claimed from these containers. Official
Antithesis documentation says nested hardware virtualization is unsupported.
Native ZFS, KVM, Firecracker/jailer, systemd, mount/cgroup ownership and physical
isolation need their existing NixOS/native acceptance or an explicitly scoped
software-emulation plan. The pinned Inception guest needs 32 GiB, versus the
documented default Antithesis machine memory of 10 GB.

## Governing source and contracts

Read `AGENTS.md`, `CONTRACTS`, `nix/CONTRACTS`, `nix/domains/artifacts/CONTRACTS`, the
architecture overview/index, ADR-0027/0030 inheritance, component guidance and
the code-contracts/documentation skills. The applicable package contracts require:

- Supplied pinned Nixpkgs inputs, matching OTP patch/Elixir runtime, and retained
  toolchain analysis metadata.
- Maintained source, reviewed dependency hashes, sandboxed native builds and
  ordinary builds offline; no working-tree deps, `_build`, credentials or
  generated frontend bundles as release inputs.
- Runtime configuration deferred to startup, no production build secrets and no
  usable packaged fleet cookie.
- Complete release closure, including Lilly's canonical host tools, unshare,
  static Firecracker/jailer references.
- Verification claims limited to their executed scope. Observability and SDK
  assertions must not acquire application authority or expose payloads/secrets.

Research-only architecture/HLDD impact: none. Implementing the suggested source,
dependency, package or verification seams changes documented build/test behavior
and requires architecture/ADR/HLDD and contract reconciliation in the final change.

## Exact current package interface

`nix/domains/artifacts/default.nix` takes
`{ pkgs, encryptedCrashDumps ? false, privateServiceRoots ? [] }`.
Flake application packages use locked `buildNixpkgs`; host NixOS configurations and
machine-test kernels use separately locked stable `nixpkgs`. Do not mix them.

| Application | Package attr | Existing release check |
| --- | --- | --- |
| Marshall | `packages.x86_64-linux.marshall` | `checks.x86_64-linux.marshall-release` |
| Lilly | `packages.x86_64-linux.lilly` | `checks.x86_64-linux.lilly-release` |
| Audi | `packages.x86_64-linux.audi` | `checks.x86_64-linux.audi-release` |
| Porsche | `packages.x86_64-linux.porsche` | `checks.x86_64-linux.porsche-release` |
| Ziggy | `packages.x86_64-linux.ziggy` | `checks.x86_64-linux.ziggy-release` |
| Brady | `packages.x86_64-linux.brady` | `checks.x86_64-linux.brady-release` |
| Galileo | `packages.x86_64-linux.galileo` | **No `galileo-release` export** |
| Enrico | `packages.x86_64-linux.enrico` | `checks.x86_64-linux.enrico-release` |

The entire package attrset is also available at
`legacyPackages.x86_64-linux`. Relevant additional attrs are `dependencies`,
`cedarCargo`, `toolchain`, `hostTools`, `terminald`, `terminaldChecks`, `lyra`,
`lyraLinux`, `vscodeWeb`, `vscodeWebBroker`, `guest`, `ubuntuGuest`,
`inceptionGuest`, `inceptionProbeGuest`, `imageBuilder`, `mkUbuntuGuest`,
`smtprelay`, `underclass`, `browser`, and `encrypted`.

Public guest attrs are `packages.x86_64-linux.guest`, `ubuntu-guest`,
`inception-guest`; `lib.mkUbuntuGuest` exposes customization. Public encrypted
release attrs exist for Marshall/Lilly/Audi/Brady/Porsche. The default is Marshall.

`scripts/package_release.sh` accepts only
`marshall|lilly|audi|porsche|ziggy`. It builds the current source-backed check and
package, queries all requisites, and exports the closure as a NAR. It is not a
complete eight-application packaging command. Add the missing Galileo release
payload probe/check before claiming eight checked releases. The shared probe's
`case application do` currently has neither Galileo nor Enrico branches: the
exported Enrico check therefore has a source-evidenced `CaseClauseError` path,
not merely absent extra module assertions. Add both real payload branches.

`nix/domains/artifacts/release-bundle.nix` is a legacy wrapper taking
`{ pkgsPath, releaseDirectory, application }`, supporting only
Marshall/Lilly/Audi/Porsche. It copies an existing release directory. It is absent
from the current flake build path and should not supply new harness images.

## Source selection and harness-only compile seams

`nix/domains/artifacts/applications/source.nix` takes `{ lib, application }`. For each app it selects
`mix.exs`, `mix.lock`, `lib`, `config`, plus protocol and diagnostics libraries.
Request accounting is included for every app except Lilly. Marshall additionally
includes `assets` and all `priv`; Audi includes `priv`. Generated Marshall asset
bundles, cache manifests, gzip/fingerprinted output and `node_modules` are removed.
Application tests and test support, root reports, local deps and `_build` are not
release inputs.

Marshall's `priv/hldd` **is a real release input**. `Marshall.Handbook` and
`Marshall.Documentation` compile reviewed Markdown into module attributes using
`@external_resource`. Updating the HLDD can change the real Marshall derivation.
Do not exclude it as a report-only directory or embed a stale release.

A new `antithesis/`, `.antithesis/`, `elixir/antithesis/` or test-support file will
not enter a production release through the current source allowlist. A concrete
seam must deliberately select its Mix metadata and source, and compile it only in
the harness build. Prefer an explicit package option with a closed set of local
source paths and a default that preserves the ordinary production release.
Keep harness builds in `MIX_ENV=prod`: Marshall's runtime validation is keyed to
production configuration. Globally switching to `MIX_ENV=test` imports test
helpers/consumers and cannot demonstrate independent production releases.

If Mix deps/elixirc paths use a build flag, supply the same flag to `fetchMixDeps`
and `mixRelease`, not just one. Preserve local dependency relative paths in the
fileset. FetchMixDeps output hashes must be reviewed when its output changes;
its `.overalls-mix.lock` snapshot is checked against release `mix.lock`, preventing
old fixed-output deps from silently compiling against a changed lock. Pure local
source changes do not automatically imply dependency-output hash changes.

Git flakes omit untracked files. Stage newly added source, lock, script and Nix
inputs before `nix eval` or `nix build`, then review the index. Do not commit or
stash merely to make inputs visible. `git+file:///...` successfully evaluated the
reset worktree and excludes ignored runtime files; copying the entire filesystem
as a `path:` flake can encounter active `.devenv` sockets and include unwanted
local output.

## Pinned releases and runtime roots

All apps use `beam.mixRelease`, exact source selection, prefetched Mix deps,
`compileFlags = [ "--warnings-as-errors" ]`, `ERL_FLAGS = "+S 4:4"`,
Elixir 1.20.4 and OTP 29.0.6. The toolchain builds hash-verified upstream
sources and applies the reviewed OTP SSH host-certificate patch. The locked
mixRelease builder uses `HEX_OFFLINE=1`, `MIX_ENV=prod`, removes `releases/COOKIE`
and wraps executables with referenced runtime utilities. `stripDebug` defaults to
false in that builder; toolchain debug information is separately enabled.

Marshall compiles Cedar from locked Rust source with `EX_CEDAR_BUILD=1`,
`CARGO_NET_OFFLINE=true`, `CARGO_BUILD_JOBS=4`, and `fetchCargoVendor` verified by
`dependency-hashes.json.cedarCargo`. Assets use Nix esbuild/Tailwind executables,
then `mix ... assets.deploy`; ordinary release builds must not run Mix binary or
Rustler precompiled downloads.

Every release ships `overalls-release.json` with format, app, platform,
Elixir/OTP, `build="nix-source"`, and encrypted-dump status. Lilly additionally
references `host_tools`, static `firecracker`/`jailer` and `unshare`, and links its
host-tools directory. This reference graph is intentionally part of the release.

Extra production service requirements are outside some OTP outputs:

| Runtime | Explicit additional image/sidecar roots |
| --- | --- |
| Lilly | The release already references coreutils/diffutils/util-linux/iproute2/nftables/procps/ZFS/OpenSSH and its twelve Rust helpers; these still require supported host kernel/privilege/systemd semantics to function. |
| Enrico | `pkgs.git`, `pkgs.coreutils`, and `pkgs.callPackage ./nix/domains/artifacts/enrico-git-owner.nix {}`; the NixOS module adds them on PATH. |
| Audi and Porsche | `pkgs.openssh`, added by their service modules. |
| Independent trace custody | `pkgs.callPackage ./nix/domains/artifacts/infrastructure/trace-spool.nix {}` plus its explicit storage/receiver configuration; not silently inside each OTP release. |
| Guest OTEL/SLO receiver | `pkgs.callPackage ./nix/domains/system/otel-guest/receiver.nix {}` and its runtime sockets/configuration. |
| Browser workload | Pinned Chromium/Node/Python/Playwright packages, fonts and generated browser artifacts; never a Playwright startup download. |

Use explicit store paths in entrypoints and `PATH` for fixed helper lookup. Supply
private synthetic runtime files in the container's own writable state; generate
cookies at startup, retain `RELEASE_DISTRIBUTION=none` where production services
already use it, and keep release temp/state paths writable. A scratch image needs
`/bin/sh`, `/usr/bin/env`, passwd/group/NSS handling and CA files where the actual
programs expect them. Packaging shell/tools does not establish host privilege.

## Recommended daemon-free OCI construction

Use the same locked `pkgs` and current `built.<app>` outputs. The locked
`pkgs.dockerTools.buildLayeredImage` takes `name`, optional `tag`, `contents`,
`config`, `architecture`, `created`, `mtime`, `maxLayers`, `extraCommands`,
`fakeRootCommands`, `includeStorePaths` and `includeNixDB`; its wrapper additionally
accepts `compressor`. In this pin, **`contents` is the layered-image option**.
`copyToRoot` belongs to `dockerTools.buildImage`, which also offers `runAsRoot`
(requiring a build VM when used).

For layered images, `includeStorePaths=true` is the default and computes store
closures from both root contents and image config. Retain it. Do not set
`includeStorePaths=false` and do not discard Nix string context on executable
paths. Use `contents = [ rootLayout ]` where `rootLayout` is a `pkgs.buildEnv`
or equivalent structured root containing deliberate symlinks to release/tool
outputs. Use explicit store-backed `config.Entrypoint`/`Cmd`; choose
`architecture="amd64"`, fixed `created`/`mtime`, and a digest-derived tag rather
than `latest` or `created="now"`. `includeNixDB=false` is adequate for application
runtime; include a Nix DB/cache only for explicitly intended nested builds.

The pinned dockerTools provides `binSh`, `usrBinEnv`, `fakeNss` and
`caCertificates`. For unprivileged app users, install a reviewed passwd/group
layout with explicit UID/GID rather than relying on root-only defaults. Root
creation can use `extraCommands`/`fakeRootCommands` without needing an image
build daemon or a privileged runtime.

Load the resulting Docker archive into the rootless Podman Docker-compatible
engine, then tag/push only the authorized concrete images. A Compose build flow
can instead copy an explicitly materialized root containing **all** closure
store paths into a `FROM scratch` Dockerfile. Its build context must be generated
from `pkgs.closureInfo`/the actual requisite graph, not from the repo root or a
live host `/nix/store` mount. A NAR is an export artifact, not a runnable rootfs.
Dockerfiles with prebuilt closure contexts must have deterministic inputs and
must not reinstall dependencies or fetch latest binaries.

## Rust SDK, coverage and symbols

Official docs currently show Rust SDK `antithesis_sdk = "0.3.0"` and modern
instrumentation crate `antithesis-instrumentation = "0.1"`. Select an exact
available patch for each, record it in Cargo.lock with checksums, and vendor it
using the supplied pinned Nix Rust platform. Ordinary compilation must use
`--locked --offline`; no `curl` of `libvoidstar.so` or unpinned Git/crates at
runtime. The modern shim loads the Antithesis runtime; a source reference
`use antithesis_instrumentation as _;` is required to keep it linked.

Call `antithesis_init()` once at process initialization for the Rust assertion
catalog. Do not disable the SDK's `full` feature in harness builds. For Elixir,
the documented fallback SDK is atomic newline-delimited JSON messages appended
to `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl`; no official Elixir coverage instrumentor
appears in the retrieved support list. A Rust bridge or fallback events can
provide assertions, but must not be called BEAM source coverage.

For ordinary non-LTO `x86_64-unknown-linux-gnu` Rust builds, the documented flags
are `-Ccodegen-units=1`, `-Cpasses=sancov-module`,
`-Cllvm-args=-sanitizer-coverage-level=3`,
`-Cllvm-args=-sanitizer-coverage-trace-pc-guard`,
`-Cllvm-args=-sanitizer-coverage-pc-table`, and
`-Clink-args=-Wl,--build-id`. Either disable release LTO in the harness profile
or use the documented matching lld link-time pipeline. Do not combine both
instrumentation pipelines.

Most Lilly helpers, Lyra, terminald and vscode-web-broker declare
`[profile.release] strip=true, lto=true`. Setting Nix `dontStrip=true` alone
cannot retain symbols already removed by Cargo. For the simpler harness build,
set `CARGO_PROFILE_RELEASE_STRIP=false`,
`CARGO_PROFILE_RELEASE_DEBUG=2`, `CARGO_PROFILE_RELEASE_LTO=false`, retain
codegen-units=1, and `dontStrip=true`; verify the effective compilation commands.
Lyra explicitly overrides `RUSTC` with a hash-verified 1.97.1 toolchain and uses
cargo-zigbuild, so replacing `pkgs.rustc` alone misses its production compiler.
Terminald, guest broker and Lyra helpers use static/musl builds. The retrieved
instrumentation recipe is for GNU; musl instrumentation/loader behavior needs
actual validation, or a clearly scoped GNU harness variant of maintained source.

Put each instrumented binary/library or its matching split debug file in the
**same image's `/symbols`**; symlinks to included store paths are supported.
Validate `nm` for text symbol `antithesis_load_libvoidstar`, `readelf -S` for
`__sancov_guards` and `__sancov_pcs`, `readelf -n` for a GNU build ID, and available
DWARF. With link-time instrumentation, verify coverage hooks are called rather
than jumped to. Do not instrument dynamically unloaded libraries unless their
load lifetime satisfies documented `RTLD_NODELETE`/no-dlclose requirements.

The guest kernel wrapper already splits debug output and verifies its stripped
ELF load image. The guest artifact intentionally does not retain the debug
reference: symbols require an explicit `guest.bootKernel.debug` root. Existing
Inception offline seeds deliberately omit compilers/source/vendor/debug outputs;
they cannot serve as an arbitrary instrumented offline rebuild cache.

## Rust, Python, frontend and guest pins

Offline evaluation of target locked build inputs returned Rust/Cargo 1.97.1,
Zig 0.16.0, cargo-zigbuild 0.23.0, Node 24.19.0, Chromium 151.0.7922.173,
esbuild 0.27.2, Tailwind 4.3.3 and `pkgs.python3` 3.14.7. The repo's
Ruff/ty language target is Python 3.13; explicitly use `pkgs.python313` when that
runtime is required rather than assuming `pkgs.python3` is 3.13. Target stable
host input has Rust 1.95.0, Python 3.13.15, Linux 6.12.109 and static Firecracker
1.15.1, versus build Linux 6.12.104/static Firecracker 1.16.1; keep them distinct.

Browser extension build uses exact package.json dependencies plus package-lock
and `fetchNpmDeps` hash, `npm --ignore-scripts` and fixed archive epoch; its type
gate is strict (TypeScript 5.9.3/Playwright Core 1.61.1). Editor uses pinned
Code OSS 1.141.0 commit `2a59476c9bfcb90b3ddc372c36762471b7dfad1c`, Node version
assertion, reviewed patch stack, fixed npm cache, source-built native modules,
four hash/signature-locked Open VSX defaults, and
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`. Package these outputs and pinned Chromium
instead of rebuilding editor/extension downloads at harness startup.

Frontend compiler coverage remains a separate explicit seam: Marshall and editor
currently minify/digest assets, editor patches remove sourcemap CDN references
and filter source-map files, and shipped xterm/ECharts/Mermaid inputs are already
compiled. Signed builtin VSIX bytes cannot be rewritten while retaining their
current signature/provenance checks. Do not claim browser source coverage merely
from exercising those packages. Underclass and SMTP relay are pinned separate
packages; Underclass's own Cargo checks are disabled due to its nested Hegel
build, and SMTP relay declares `ldflags=["-s" "-w"]`, requiring explicit symbol
changes if those native binaries are selected for coverage.

Both guest families use the supplied `linuxPackages_6_12` and real hashes/lengths
in manifest version 4. NixOS guest takes
`{ pkgs, terminald, lyraLinux, vscodeWeb ? null, vscodeWebBroker ? null,
extraModules ? [], imageName ? "lilly-nixos-x86_64", minimumMemoryBytes ? ...,
privateServiceRoots ? [] }`. Public defaults include editor and require 2 GiB.
`privateServiceRoots=[]` does not provide the enrolled host private-service/source
trust capability.

Ubuntu builder is curried: first supply pinned tools, then
`{ imageName ? "lilly-ubuntu-26.04-x86_64", packages ? [],
packageLock ? ./packages.lock.json, files ? {}, caCertificates ? [],
privateServiceRoots ? [], minimumMemoryBytes ? ... }`. Requested packages must
exactly match its reviewed snapshot lock. Extra files have validated allowed
destinations and must not replace builder-owned platform files. It assembles
prefetched base/debs with APT under a network-isolated VM; offline guest image
assembly still requires that build VM support. Its locked Ubuntu Python differs
from the repository Python static target.

## Build identity and report-only exclusions

Derive identity from current selected input paths and content, not a handwritten
fixed old revision. Include source files/modes/symlink targets, locks, Nix recipes
and patches, runtime config schemas, Dockerfiles/entrypoints/Compose, workload
commands, compiled property adapters, SDK/instrumentation locks/options, public
fixture trust and the evaluated derivation/runtime closure identities.

Exclude generated evidence/reports/scratchbook prose, local caches, `target`,
`deps`, `_build`, `node_modules`, image archives, `result*`, logs, mutable runtime
state and the fingerprint/metadata file itself. Keep exclusions narrow and
reviewable. Do not blanket-exclude Markdown or `priv`: Marshall's handbook/public
docs are compiled production input. Root architecture reports generally do not
enter release selection, but HLDD chapters do. Adding a source/library/helper
must automatically expand the fingerprint inventory; excluding report-only
changes must not hide a new executable or compile option placed beside a report.

Suggested build record: schema version; production snapshot/dirty indicator;
sorted source manifest digest; flake.lock digest/locked revisions; all eight
release drv/output paths; harness variant flags; SDK crate patch/checksum;
instrumentation target/flags; symbols inventory/build IDs; image archive hash and
registry digest; Compose/config digest. Append execution results separately so
recording test evidence does not cause the artifact being tested to rebuild.

## Compose and launch constraints

Use Linux/amd64 images. Registry destination supplied for this task is
`us-central1-docker.pkg.dev/molten-verve-216720/orbitinghail-repository`.
Use the existing rootless amd64 Podman engine at
`DOCKER_HOST=unix:///run/user/1000/overalls-antithesis-reset-podman.sock` with the
actual docker-compose 5.4.0 and snouty 0.7.2. This agent's default shell does not
have a `docker` executable; preserve the root agent's intended Docker-compatible
CLI wrapper PATH in image-load/build/validation commands as well as DOCKER_HOST.

Provide `image` plus concrete local `build` definitions when using the Compose
build workflow. Config image must place `docker-compose.yaml` at its root and
include all needed closed runtime config. Explicit unique `container_name` and
matching hostname, health checks, dependency readiness and `init:true` follow
official guidance. Avoid hostname underscores, custom logging drivers,
`internal:true` networks and pull_policy. All images/dependencies are prepared
before launch; no internet, dependency pull or image build exists inside the run.

Close every Compose interpolation with deterministic values available in config,
not undeclared shell state. `snouty validate` compares normal and scrubbed
Compose resolution. It starts the local system, watches a temp bind-mounted SDK
setup event, then discovers command structures under
`/opt/antithesis/test/v1/{test_name}/...`. **It does not execute the test commands.**
Run relevant commands independently after validation. The setup-complete signal
must follow actual migrations, healthy services, baseline fixtures and oracle
readiness. Bound waits and fail setup explicitly when those prerequisites fail.

The Antithesis output directory is an output sink in the remote environment;
do not read it back as authority or persist state there. Keep application and
oracle state in ordinary private volumes/directories. No Docker socket, host
credential mount or undeclared host closure belongs in the remote Compose spec.

## Actual validation and remaining gates

Executed read-only: target `nix flake metadata --offline --no-write-lock-file
--json`; target `nix eval --offline --no-update-lock-file` for all eight
production release drvPaths; exported release-check-name evaluation; locked
tool-version evaluation; `snouty docs --offline` retrieval and CLI help/version
inspection. Target metadata fingerprint at inspection was
`73fe84fbba0ef671e41b0843990986294d099a0b85cddd04369e5edd54445ca5`, with dirty
revision `9fe1e493b2090d44bacd16089049cd12b316d58a-dirty`; continuing root edits
must acquire their own evaluated fingerprint.

Before launch: stage/review fresh inputs; evaluate all harness attrs and ensure
report-only churn leaves runtime inputs unchanged; prefetch locked dependencies;
compile eight releases and all selected native/workload artifacts; run existing
release checks plus missing Galileo payload check; check symbols and assertion
catalogs; build/load/pin image identities; validate rendered Compose and real
offline startup; separately execute tests; run required project precommit/type,
contract, ADR and HLDD gates for the changed scope. Record failures and preferred
native/NixOS coverage gaps separately. No passing build/runtime/remote claim is
established by this research artifact.

## Official documentation consulted

- https://antithesis.com/docs/setup/overview/
- https://antithesis.com/docs/setup/docker_compose/
- https://antithesis.com/docs/best_practices/docker_best_practices/
- https://antithesis.com/docs/configuration/the_antithesis_environment/
- https://antithesis.com/docs/reference/sdk/rust/
- https://antithesis.com/docs/reference/sdk/rust/instrumentation/
- https://antithesis.com/docs/reference/sdk/fallback/
- https://antithesis.com/docs/product/writing_tests/instrumentation/coverage_instrumentation/

Retrieved through the installed snouty documentation CLI in offline mode; these
are cached official docs, not evidence of this tenant's negotiated resource or
kernel configuration. Exact Compose validation behavior is grounded in installed
snouty 0.7.2 `validate --help`.
