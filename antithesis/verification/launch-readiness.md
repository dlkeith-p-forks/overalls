# Antithesis launch-readiness review

Reviewed 2026-10-13 against the reset worktree's `antithesis/config` source,
selection materializer, the installed Snouty 0.7.2 command help, and official
Antithesis pages retrieved with `snouty docs`. Local control-core acceptance is
now recorded below: the pinned no-cache Compose build succeeded, the selected
config was materialized and identity-frozen, and
`snouty validate antithesis/runtime/configs/control-core --timeout 300` reached
`setup_complete` and found nine drivers. No registry push or hosted run was
performed. The identity and source remain subject to the final source cutoff.

## Required local configuration and image boundary

The base config directory is `antithesis/config`: it contains
`docker-compose.yaml`, with `pg`, `migrate`, `marshall-a`, `marshall-b`,
`lilly-a`, `enrollment`, and `workload`. The image names are local tags, and the
build contexts point to the repository root and the staged Nix closures under
`antithesis/build/contexts`. The workload image also copies the staged command
selection from `antithesis/build/selected-test/v1`. The Antithesis environment
cannot build or pull images after it starts. The official setup guide requires
Linux container images that run without internet access, and the Docker best
practices require all images to be built and available before launch. Snouty's
`launch --config` uploads required locally built service images and generates a
config image; it does not build or pull missing images. The current local tag
names and `build` plus `image` declarations fit that workflow, conditional on
the exact selected images and their Nix contexts being current in the same
engine that Snouty uses.

For the base graph, the discovery command is
`snouty validate antithesis/runtime/configs/control-core` after materialization
and identity freeze.
The installed CLI says it starts the Compose file in that directory, waits for
`setup_complete`, then scans `/opt/antithesis/test/v1` in running containers for
recognized command names; it checks their structure but does not execute them.
It compares the local Compose render with a scrubbed environment before starting
and fails on variable divergence. Its default setup timeout is 120 seconds.
The workload allows 180 seconds for its own readiness probe, after a serial
PostgreSQL migration, Marshall HTTPS readiness, and operator enrollment; the
explicit local validation timeout should therefore cover the *measured* full
startup, rather than assuming the default is enough. A successful structural
scan would still leave command behavior and hosted runtime untested.

`.devenv/antithesis-environment.json` records a rootless Podman API socket,
Docker Compose v2 provider, `SNOUTY_CONTAINER_ENGINE=podman`, and an online
doctor pass at 08:54 UTC. The launch skill requires the build and validation to
use the same engine and Compose CLI reported by `snouty doctor`. Reconfirm that
pair when the source and images are final. Snouty injects a writable temporary
bind mount into every container to observe `setup_complete`; its CLI help says
`SNOUTY_TEMP_DIR` must point to a path shared with the engine if the engine runs
in a separate VM or on another host. The recorded local Unix socket suggests a
same-host engine, but the bind mount has not been exercised here.

## Selected-profile packaging

`repository-origin.json` selects the base file plus `compose.origin.yaml` and
`compose.enrico.yaml`; `access-smtp.json` selects the base plus
`compose.smtp.yaml`. Local `docker-compose -f ... -f ... config` and
`identity.py` render those ordered files, while the official `snouty validate`
and `snouty launch --config` interfaces accept only a config directory
containing one `docker-compose.yaml`. `selection.py materialize` now writes that
standalone hosted file and a receipt under `antithesis/runtime/configs/<profile>`
for every selection, including `control-core`. It removes local build directives,
rejects unsupported local mounts and config files, and retains the selected image
tags. `identity.py` checks the materialized file, receipt and inspected image IDs
against the same rendered source graph. Passing `antithesis/config` to Snouty
would still select the base graph and could validate or submit the wrong roster.
For `control-core`, the pinned rootless Podman/Compose environment completed a
no-cache build for the selected images. The materialization receipt records
Marshall `sha256:1d266774c335216e7a0efe74d66226f825ad62d0152dcf1cb287711cf0439a10`,
Lilly `sha256:e5b62b12eb280e64faa3a4fd99751d643835415e46ee20302630bae365a5b6b1`,
PostgreSQL `sha256:3cb266621ed1fd7bda9152b58dd0a68c215554def11c1ba8965c0b7a9a30bf8f`,
and workload `sha256:5ce4f3660c9ac0afd3f81063ea48bb5e31ddfa8113fadefa042c404147bb8ee6`.
The identity ledger records identity SHA-256
`8c0ff191363e07367a213a9ee6ff73776c5043801838ded30457539dfcbe41f6`.
The freeze and validation describe this exact local artifact set; rebuilding or
changing source during the final cutoff requires a new materialization and freeze.
The successful validation was structural: it observed `setup_complete` and nine
driver names, but did not execute those drivers or establish hosted behavior.

The official setup guide describes a config image with `docker-compose.yaml`
and any needed configuration files. Snouty's `launch --config-image` accepts a
prebuilt config image as an alternative, but that path transfers responsibility
for its exact file content and referenced service images to the builder. Neither
path supports an implicit local multi-file override selection.

## Cgroup, mounts, and health boundaries

The base `lilly-a` service sets `cgroup: host`; its source comment says local
rootless Podman's private cgroup namespace omits the `cpuset` data read by the
hosted collector.
The Antithesis environment page documents an x86-64 simulated host, injected
device drivers and mounts, container network namespaces, CPU throttling, and no
nested hardware virtualization. It does **not** specify that a Compose host
cgroup namespace is honored, which cgroup filesystem paths are exposed, or that
host cgroup state remains meaningful under simulated faults. This is a hosted
compatibility and observation gap, not a proven rejection or a proof of native
capacity. Local Compose rendering or a local Podman health pass cannot close it.
An Antithesis setup run or vendor confirmation is needed before depending on the
host-cgroup reading; any unavailable measurement must leave capacity claims
unavailable.

The base service state and credential shares use named volumes, not source-tree
bind mounts. The official Compose setup guide permits mounted volumes but does
not establish the fault or restart semantics of these named volumes. The
optional guest overlay requests `/dev/net/tun`,
`NET_ADMIN`, and a read-only witness mount; the satellite overlay requests a
shared `lilly-a` network namespace and `NET_ADMIN`. The official pages retrieved
do not certify those requested device, capability, namespace, or read-only mount
semantics in the hosted environment. They remain optional profile acceptance
questions. The host and recorder TCG overlays also request 8 GiB and 3 GiB
container limits, respectively; the environment page says the default machine
has 10 GiB total for containers plus its own reserve, so those profiles need
measured memory admission before use.

The Docker best practices explicitly recommend Compose `healthcheck` and
`depends_on` for startup order. In the base graph, PostgreSQL uses `pg_isready`;
Marshall's serving instances probe their real HTTPS readiness endpoints; Lilly
checks its local status socket for an authenticated v4 Control connection and
terminal authority. Migration's `/tmp/migrations-ready` and enrollment's
`/tmp/enrollment-ready` markers represent completion of those specific startup
actions, as the entrypoints and local contract say; they do not establish
ongoing service health or physical guest execution. The workload alone emits
`setup_complete` after its independent SQL, HTTPS, and host-report checks. A
local validation should confirm these checks actually become healthy and that
the event is observed, then command execution and hosted behavior need their
own evidence.

## Hold points before any submission

1. Retain the frozen selected identity through the final source cutoff. Any
   rebuild or source change invalidates the recorded control-core identity and
   requires a fresh materialization, image-ID check and validation.
2. The local control-core build and
   `snouty validate antithesis/runtime/configs/control-core --timeout 300`
   passed. A hosted launch still requires a separate reviewed submission and
   would add no evidence for command behavior by itself.
3. Treat hosted cgroup namespace/device/mount behavior and selected optional
   profile health as unverified until a setup run or direct vendor evidence
   establishes them. No physical isolation or native capacity claim follows
   from a local healthcheck.

This review changes no product behavior, architecture decision, or HLDD test
evidence; it only records the current launch gates. ADR-0017's physical proof
boundary and ADR-0033/ADR-0043's native machine evidence remain unchanged. No
HLDD chapter or scenario receipt is upgraded by this review.

## Sources

- [Antithesis Docker Compose setup guide](https://antithesis.com/docs/setup/docker_compose/): config-image layout, offline images, local startup, and setup signal.
- [Antithesis Docker best practices](https://antithesis.com/docs/best_practices/docker_best_practices/): prebuilt images, healthchecks, startup dependencies, and `init`.
- [The Antithesis environment](https://antithesis.com/docs/configuration/the_antithesis_environment/): simulated host, CPU/memory limits, runtime injections, and network boundary.
- [Snouty CLI](https://antithesis.com/docs/ai/snouty/): config-directory validation and launch workflow.
- Installed `snouty validate --help`, `snouty launch --help`, and `snouty doctor --help` (read-only inspection on 2026-10-13).
- Local source: `antithesis/config/docker-compose.yaml`, selected `compose.*.yaml` files, `antithesis/Dockerfile`, `antithesis/entrypoints`, `antithesis/workload/core/bootstrap.py`, and `antithesis/verification/selections`.
