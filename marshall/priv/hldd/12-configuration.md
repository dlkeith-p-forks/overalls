# Nix cache trust and fallback

Every Nix-running host and guest imports the shared cache declaration from
[the platform cache module](repo:nix/platform/nix-cache.nix). Nix keeps
`https://cache.nixos.org/` and adds `https://overalls.cachix.org`; paths from the
second endpoint are accepted only with the pinned
`overalls.cachix.org-1` public key. Signature verification remains required,
and fallback permits a local build or another configured substituter when Cachix
is unavailable. The kexec installer and Ubuntu guest `nix-daemon` use the same
values. The Overalls and Dungarees fleet hosts also enable the NixOS
`cachix-watch-store` agent for cache `overalls`. Its scoped API token is
delivered as the SOPS bundle `overalls-cachix` and the agent requires that bundle
unit before starting. The token is not part of evaluated configuration or guest
images; live upload and rotation evidence remain unrecorded.

No Cachix write token is embedded. The evaluation check
`nix-cache-configuration` covers host, guest and fleet fixture declarations; it
does not establish live reachability, cache hit rate or physical rollout.

# NixOS machine configuration

## GitHub OAuth deployment inputs

NixOS exposes `services.marshall.github.clientId`, `clientSecretFile` and
`redirectUri`, all defaulting to `null`. Configure all three or none. The unit
wrapper removes inherited GitHub settings, supplies only module values and loads
the secret through a systemd credential. Partial module configuration fails
evaluation; the runtime independently validates complete values and callback
syntax. No callback-host equality with the configured Marshall origin is implied.

`services.marshall.githubToolsRelease` and `services.ziggy.githubToolsRelease`
select the same immutable public client release. Marshall receives
`MARSHALL_GITHUB_TOOLS_MANIFEST_FILE` and validates the
closed content-addressed inventory and artifact sizes/digests before the current
executor can obtain a fenced maintenance attempt. The option installs no GitHub
secret in the guest; a configured manifest is not a recorded native upgrade.

Matching `services.marshall.githubBootstrapRelease` and
`services.ziggy.githubBootstrapRelease` provide public source-built executor
artifacts for retained machines that lack the tool capability. Marshall receives
`MARSHALL_EXECUTOR_BOOTSTRAP_MANIFEST_FILE`. The closed inventory and fixed
bootstrap program remain separate from tool-installation authority and receipts.

`services.marshall.githubRestoreEpochFile` defaults to
`/var/lib/overalls-marshall-recovery/github-restore-epoch`. Supported database
restore publishes a fresh common fleet UUID there before changing the database;
the marker remains and each unit applies it in non-serving prestart. Operators
must stop all replicas and distribute that same epoch before any restart. Local
masking cannot establish remote fencing; direct raw database replacement is not
automatically detectable.

Configure `MARSHALL_GITHUB_CLIENT_ID`, `MARSHALL_GITHUB_CLIENT_SECRET_FILE` and
`MARSHALL_GITHUB_REDIRECT_URI` together. All absent disables setup; partial or
malformed configuration refuses startup. Production uses the exact registered
HTTPS redirect with path `/auth/github-com/callback`, no query, fragment or user
information. Explicit loopback development/test settings may use HTTP.

The client-secret setting is an absolute private runtime-file path, not secret
bytes in application configuration or Nix values. The domain reads it at the
exchange boundary. Existing Cloak keyring, Galileo control credentials, private
TLS and guest trust are required. The shared PostgreSQL-backed `github` queue
uses concurrency two and AshOban scheduling. The hostname needs no wildcard SAN
change. See [operator configuration](repo:docs/services/github-com.md) and
[services](#services).

## Guest coding CLI configuration

Both image builders use
[one pinned package/settings source](repo:nix/domains/artifacts/guest/coding-clis.nix).
Codex reads `/etc/codex/config.toml`: `model_provider = "ziggy"`, provider
`base_url = "https://llm.internal/openai/v1"`, `wire_api = "responses"`,
`requires_openai_auth = false`, `supports_websockets = false`,
`approval_policy = "never"`, `sandbox_mode = "danger-full-access"` and
`check_for_update_on_startup = false`. Model selection remains native client
behavior; native user/CLI settings may override Codex system defaults. No per-user
configuration is generated.

Claude reads `/etc/claude-code/managed-settings.json`. Its `env` sets
`ANTHROPIC_BASE_URL=https://llm.internal/anthropic`, nonsecret
`ANTHROPIC_AUTH_TOKEN=ziggy`, `DISABLE_AUTOUPDATER=1` and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. The package's forced plugin-update
default is removed and native managed settings disable plugin auto-updates. No
real provider key or login token is an image input. Its managed settings also set
`permissions.defaultMode = "bypassPermissions"` and `sandbox.enabled = false`,
and `skipDangerousModePermissionPrompt = true`, using native dangerous-mode
precedence. This removes client prompts and client
command sandboxing while retaining guest/VM/network/Marshall boundaries.
Production Anthropic remains disabled and these requests return
`provider_unavailable`; this configuration is not provider enablement.

`CODEX_CA_CERTIFICATE`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`,
`REQUESTS_CA_BUNDLE` and `NIX_SSL_CERT_FILE` point to
`/etc/ssl/certs/ca-certificates.crt`. NixOS supplies session and PAM variables. Ubuntu exports
them through `/etc/profile.d/overalls-coding-clis.sh`, global Bash startup and
PAM's `/etc/environment`, so native terminal and SSH accounts retain verified
TLS. Changes apply to rebuilt images for future provisioning. Native user
settings retain ordinary precedence and may override defaults where supported;
guest network and Marshall authority checks remain independent.

## Experimental Antithesis build selection

The root flake exports optional `antithesis-NAME-context` packages from pinned
source-built closures. Its ordinary application packages use
`antithesisSdk = false` and `antithesisGuest = false`. A selected harness build
sets `ANTITHESIS_HARNESS=1` during both fixed-output dependency fetch and
release compilation; the separate Lilly guest selector also sets
`ANTITHESIS_GUEST=1` and requires the SDK selector. The optional inner-host
release additionally selects `ANTITHESIS_INTEGRATED_HOST=1` at compile time to
use measured ZFS and TCG-specific host ownership; it is not the default
controlled container release. Each of the eight Mix
projects includes the fallback SDK only for the harness selector. Changing a
runtime environment variable on an ordinary release does not install its
harness modules or switch Lilly's compiled executor. These selectors are build
inputs for disposable test contexts, not deployed NixOS service options.

The default [Compose fixture](repo:antithesis/config/docker-compose.yaml)
declares PostgreSQL 18, migration, two Marshall processes, one controlled
Lilly, enrollment and workload bootstrap. The fixture's TLS, signing,
encryption, database and host credentials are generated in private runtime
volumes. The workload receives only its CA, nonsecret fixture, SELECT-only
database role and a separate read-only Control credential copy. Missing or
inconsistent retained credential state refuses startup. The configured hosted
pool has a typed identity but no measured native capacity; it never enables
placement admission. See [verification](#reference) for the exact evidence
limits and [security](#security) for authority boundaries.
The controlled Lilly container selects `cgroup: host` because the tested
rootless Podman private cgroup namespace omitted `cpuset`. Its collector
derives the process's actual unified cgroup v2 subtree from `/proc/self/cgroup`
and reads that subtree and ancestors under `/sys/fs/cgroup`; it refuses a
missing, ambiguous, escaped or unreadable path. It does not substitute the
configured native Lilly slice for the container's own limits. The direct
preflight observed a host-view mount. A later local Compose run committed a
fresh report from the controlled container with cgroup-derived effective CPU
and memory fields; raw cgroup files were not independently compared. Its
pool capacity remained nil and execution readiness false.
The enrollment process selects Marshall operator mode with an endpoint
configured `server: false`. It keeps Repo, Vault, authorization, PubSub and the
non-listening Endpoint needed for real WebAuthn origin/RP identity, while
background jobs and serving listeners stay off. Its private fixture contains
three synthetic accounts and passkeys after the recorded local diagnostic.
Optional Compose overlays select guest/inner-host, origin/SMTP, satellite,
Enrico and recorder fixtures with their own state and credentials. A default
control-core setup signal does not validate these additional overlays.
`compose.inner-private.yaml` selects the separate `private-host-vmm` context
after `compose.host-vmm.yaml`; its inner Audi/Ziggy/Galileo roles and guest
image use runtime PKI and a boot-bound trust receipt. The source-built fourth
private host image booted directly under TCG, but this Docker variant has not
started and its private roles lack serving credentials.

## Browser extension package

`services.marshall.marvinPackage` selects the immutable unsigned Chrome/Firefox
launcher package and defaults to the repository's `browser` output. Set it to
`null` to disable extension downloads. After loading other environment files, the
wrapper removes any inherited `OVERALLS_MARVIN_RELEASE` and supplies the selected
Nix-store output, or an explicit empty value for null. Environment files cannot
override this selection. Public `/bin/chrome.zip`, `/bin/firefox.xpi`,
`/bin/marvin/manifest.json` and `/bin/marvin/sha256/ARTIFACT` serve only the fixed
package artifacts and their metadata. The CLI's release manifest stays separate.
The extension server origin is configured by its user, not this server option. The
extension requests optional site access only for that exact saved origin when its
presence detector is configured; this local marker never changes server authority.

Build with `nix build .#marvin`; check with `nix build .#checks.x86_64-linux.marvin`.
In devenv, `marvin-build`, `marvin-check` and `marvin-watch` use the same maintained
native module/build source and lockfile-pinned tools. Release version comes from
`marvin/package.json`; archive timestamps default to the fixed ZIP epoch through
`SOURCE_DATE_EPOCH`. No signing credential or provider credential enters the build.
See [installation](#interactive) and [verification](#reference).

## Browser editor release configuration

`services.marshall.editorPackages` and `services.audi.editorPackages` map the
finite targets `linux-x64` and `win32-x64` to approved source-built packages.
Both default to `{ linux-x64 = packages.vscodeWeb; }`; an empty attribute set
disables that role's editor capability. Windows requires an explicitly selected,
reviewed native bundle and does not enter the default catalog.

Marshall's wrapper owns `MARSHALL_INGRESS_EDITOR_RELEASES`, a closed JSON object
with `version: 1` and a `targets` object mapping those target names to exact
`protocol`, `commit` and `release` descriptors. Unknown fields or targets,
malformed descriptors and duplicate release digests refuse startup. The wrapper
always sets the registry, including the empty value; inherited environment files
cannot supply editor authority. There is no singular-option or singleton-reader
fallback. Audi's versioned configuration maps `tls.editor_packages` targets to
immutable store roots, validates each package and runs a separate readiness
publisher for each release.

Apply the receipt-index migration before enabling concurrent releases. Rebuild
each host's application and generated configuration atomically. During a
coordinated rollout, a gateway serving only Linux assets cannot satisfy a
two-target registry: its editor and neutral webview discovery stays withdrawn
until both current release receipts exist. Every advertised gateway must serve
the entire configured set because neutral webview DNS cannot choose a gateway
by release. Changing either target's package changes its immutable identity and
requires corresponding image and gateway updates.

Configured editor zones must contain at least two canonical lowercase DNS labels
and at most 189 bytes, matching the shared protocol and native broker. Marshall's
module/runtime guard and editor authority refuse a single-label zone; Audi's
module and startup guard also refuse it when immutable editor assets are configured. Generic ingress with
editor capability disabled retains its existing zone rules.

The gallery and Ed25519 signing-key ring are reviewed build arguments in
[the package](repo:nix/domains/artifacts/vscode-web/default.nix), not mutable browser
preferences. Changing source, patches, dependencies, gallery settings or keys
changes release identity. The guest image manifest must declare that exact tuple;
an old or mismatched image refuses editor admission. Both guest builders embed
the complete package/broker closure offline. No first-boot installer or ambient
Nix channel participates. See [guest images](#guests) and [operations](#operations).

`services.overallsBrowserProbes.instances.nixos` and `.ubuntu` declare separate
five-minute browser journeys. Each requires private absolute runtime `fixtureFile`
and `storageStateFile` paths and fleet OpenTelemetry. Overalls declares both;
credentials are separately provisioned from an actual completed operator browser
sign-in. They are never Nix values or automatic authentication bypasses. The
closed fixture pins the machine, expected personal origin, guest OS, username/UID
and pre-existing Markdown probe file. Missing credentials leave the source without
usable coverage. Do not infer health from an enabled unit; see [monitoring](#monitoring).

The root flake is the public build interface. Applications use the pinned build
package input; hosts use the separately pinned stable NixOS input. `x86_64-linux`
is the current platform. Do not substitute ambient channels.

| Declaration | Purpose |
| --- | --- |
| `flake.nix` | Packages, modules, machine configurations, checks |
| `fleet/hosts/NAME/host.json` | Reviewed hardware, network, storage, identity, budgets (`arcMaxMiB` 24576, `guestMemoryMiB` 95232 and `guestCpuCores` 32 on both fleet hosts, ADR-0164; a ceiling decrease ships in its own push after the updater that permits it, because the compatibility predicate runs in the live updater) and encrypted document inventory |
| `fleet/hosts/NAME/configuration.nix` | Enrolled host roles and service composition |
| `nix/policy/identity/users.nix` | Named fleet users, administrative and recovery membership |
| `nix/policy/network/allowed-hosts.nix` | Reviewed perimeter source grants |
| `nix/policy/secrets/secret-documents.nix` | Public secret-document and recipient inventory |
| `fleet/guest-images.nix` | Guest artifacts selected for the fleet |

The `NAME-base` machine installs host access without enrolled roles or update
polling. The enrolled `NAME` output requires authenticated host keys and Git
custody. Role activation does not install disks.

The source registry contains only the two fleet host addresses. On enrolled
fleet hosts each entry admits TCP and UDP traffic to all listener ports; people
use the Tailscale overlay, and SSH and application authentication remain separate.

## Marshall role

A minimal role fragment uses runtime file paths for private material:

```nix
services.marshall = {
  enable = true;
  publicHost = "control.example.com";
  replicaCount = 3;
  databaseConnectionBudget = 43;
  environmentFile = "/run/overalls-secrets/marshall.env";
  instances.node01 = {
    port = 4443;
    certificateFile = "/run/overalls-secrets/backend.crt";
    keyFile = "/run/overalls-secrets/backend.key";
  };
};
```

This fragment requires the default module, host networking, secret preparation,
database trust, and the declared fleet connection budget. `replicaCount` describes
the fleet, not the number of entries on this host. An explicit single-instance
configuration is supported but has no control-plane redundancy.

Production database connections apply the fixed
[lost-client recovery settings](#recovery) at startup. The shorter TCP
acknowledgement limit affects stalled network connections; it does not cap
healthy SQL duration. Existing connections acquire changed settings only after
reconnection.

Set public proxy backends and their verified server names separately. The runtime
environment carries `DATABASE_URL`, `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET`,
`MARSHALL_CLOAK_KEYS`, and mail settings. `MARSHALL_RELOCATION_READINESS_TIMEOUT_MS`
(default 120000) bounds relocation readiness and `MARSHALL_CLONE_CLEANUP_DEADLINE_MS`
(default 300000, at most an hour) sets how long after publication a clone waits for
its source snapshot prune before completing with the hold retained (ADR-0162). All
replicas share compatible signing and encryption authority. Nix service wrappers own listener identities and selected
policy values; conflicting environment entries do not override those protections.

For isolated native tests, `MARSHALL_CONTROL_FAULT_GATE_FILE` names a local file
containing one exact control op per line, such as `lilly.relocation_keys`.
Matching requests receive `temporarily_unavailable` before domain dispatch;
the gate neither fabricates successful replies nor changes stored authority.
Unlisted ops use normal admission and dispatch. Missing configuration or an
unreadable file leaves the gate inert. Production does not configure this setting.
Changes to the file apply to subsequent requests without restarting Marshall.

Native provider compaction is disabled unless
`MARSHALL_AGENT_NATIVE_COMPACTION_CAPABILITIES` contains a JSON array of exact
OpenAI provider/model records. Each record requires `provider`, `model` and a
lowercase 64-character `evidence_digest`; Marshall validates the shape at
startup and rechecks the complete provider/model pair when queuing and claiming
maintenance. `MARSHALL_AGENT_NATIVE_COMPACTION_VERIFIED=true` is rejected as a
global switch. The digest is an operator receipt reference and does not replace
live provider acceptance evidence.

## Push notification switch

`services.marshall.notifications.enable` (default `true`) reaches Marshall as
`MARSHALL_NOTIFICATIONS_ENABLED` in both the
[pre-start and serving wrappers](repo:nix/domains/system/marshall.nix), after
any `EnvironmentFile`, and [runtime configuration](repo:marshall/config/runtime.exs)
refuses any other value than `true` or `false`. When false, `device register`
refuses with `push_disabled` (HTTP 409) and the producer is a no-op; queued
deliveries drop as `preference_off`. The Susan origin
`https://notifications.overalls.dev` is a
[compiled constant](repo:marshall/lib/marshall/notifications/susan.ex) verified
against the operating-system trust store; only a `MIX_ENV=test` build reads an
override, so no deployment setting can redirect pokes.

## Lilly role

Provisioning acceleration has no rollout switches (ADR-0159): per-pool sealed
templates, exact-boot guest SSH readiness before provision success, same-pool
block-copy clones and on-demand root-disk copies are unconditional; rollback
is a `git revert`. `services.lilly.images` entries are `{ path }` objects
(ADR-0171, ADR-0177): that is the only admitted shape, so a bare path or the
retired `standby` key refuses the configuration (`Lilly.Control.Config`
preserves the operator's order). `services.lilly.imageTemplates.budgetBytes` is
a positive per-pool budget (default 32 GiB). ADR-0177 removed the
`services.lilly.standbyDisks.*` options: every create copies its root disk on
demand. Budget reduction does not erase template journals or authorize
deletion; see [storage](#storage). The enrolled Overalls and Dungarees
configurations raise the budget to 96 GiB so the Linux templates and the
64 GiB Windows template fit together (ADR-0130, ADR-0173); activation evidence
is recorded separately. Marshall's
`pool_busy_grace_ms` (15 s, application configuration) bounds how long a busy
pool entry may extend a recent measurement's freshness and is checked against
the authority window at start.
Lilly hosts with ZFS pools also run `nix-daemon` in its own slave mount namespace
whose start wrapper unmounts every pool path before serving builds, and route root
and auto-update builds through it (`NIX_REMOTE=daemon`), so builds never hold
guest datasets (ADR-0144). A `lilly-pool-propagation` oneshot, required by
Lilly, marks each pool mount recursively private after `zfs-mount.service` so
guest mounts never propagate into other services' namespaces.
Declared configuration is separate from recorded activation in the
[SLO review](repo:docs/architecture/reviews/2026-10-02-durable-physical-slos.md).

Supply `hostId`, `controlPlane`, `credentialFile`, `egressInterface`, enrolled
`pools`, and installed image manifests. `hostId` and pool GUIDs come from enrollment;
they are not generated during service activation. Configure guest CPU/RAM budgets,
host overheads, protected networks, ingress, private services, and public trust
roots. Keep the transfer listener separate from administrative SSH.

Lilly needs root for native execution, networking, and storage. Guests run in the
managed slice with independent VMM supervision. The daemon keeps host mount
visibility; restricting it to a private mount namespace can invalidate cleanup.

## Independent observability roles

`services.overallsOtelFleet.enable` selects a `central` Overalls or `worker`
Dungarees collector over the authenticated fleet network. Metrics and trace
retention default independently to ninety days; objectives keep seven days.
`services.overallsFleetExporter.enable` supplies bounded loopback resource metrics
without a Marshall credential or diagnostic upload.

The default-enabled `services.overallsOtelFleet.traceSpool` discovers exact enrolled
application units and gives each an independent producer-authenticated socket,
private durable archive and ninety-day retention. `quotaBytes` defaults to two GiB
per producer; `pendingQuotaBytes` limits pending admission to 256 MiB within that
archive. `hostBudgetBytes` defaults to 32 GiB and refuses an overcommitted evaluated
producer inventory. Archives are separate from Tempo's quota; exhaustion refuses
new trace diagnostics without stopping a producer. Its read-only `producers`
inventory drives source health. Native helpers' stdout protocols remain private
data interfaces.

`services.overallsLogging.outputs` requires explicit sources and output budgets.
Galileo and Underclass are ordinary application sources. Stable journal shards
retain separate cursors; enabling a new source never authorizes restricted audit
or Firecracker data. `healthAddress` defaults loopback and may use only the
authenticated host fleet address; `healthPort` defaults to 9467 and is separate
from Fluent Bit's localhost counters. Source snapshots expose numbers, not archives.

Central Grafana loads reader-only log-store credentials through systemd and queries
the verified fleet TLS entry. Store insert and reader credentials retain separate
custody. Changing the reader credential requires restarting Grafana to reload it;
never place secret contents in Nix options, application environments or dashboards.
See [monitoring](#monitoring) and the evaluated [option reference](#options).

## Users and secrets

Fleet users are separate from Marshall accounts. `login` creates host access;
`admin` grants passwordless sudo; `secretRecovery` adds off-host recovery access to
inventoried documents. Revoking login at activation does not terminate existing
SSH, Mosh, or user-service processes. Handle those explicitly.

Encrypt private input from a mode-0600 file outside the checkout:

```sh
nix run .#secrets -- encrypt HOST-DOCUMENT --input /private/document.json
nix run .#secrets -- check
```

Ordinary documents need authenticated host recipients and recovery users.
Recovery-only documents explicitly have no runtime host recipients. Nix contains
ciphertext and public keys; SecretSpec/SOPS materializes runtime files. Use string
paths for private inputs, not Nix path literals that copy content into the store.
After recipient changes, rekey affected documents and verify independent recovery.
Every inventoried document receives all recovery-enabled users and only its
selected hosts; login alone grants no recovery access. Host and user key lists
permit overlap during rotation. Reconciliation requires a retained recovery
identity and replaces the data key whenever the recipient set changes.

The [option reference](#options) lists every Overalls option in the default module,
including nested records. Consult it for types, defaults and required fields.

Evidence: [host profile](repo:nix/platform/hosts/profile.nix), [Marshall module](repo:nix/domains/system/marshall.nix),
[Lilly module](repo:nix/domains/system/lilly.nix), [fleet users](repo:docs/operations/fleet-users.md),
[secret custody](repo:secrets/README.md).

## SSH host CA configuration

Set `services.marshall.sshHostCa.publicKey`, `keyFile` and `retirement` together
with `services.marshall.ingress.zone`. The public policy uses `publicHost` as its
management principal, including the effective `publicHostFile`/`PHX_HOST` override.
The private key path must be runtime-only; systemd delivers
it solely to Marshall. Manual deployments use `MARSHALL_SSH_HOST_TRUST` and
`MARSHALL_SSH_HOST_CA_KEY_FILE`. Missing policy disables public installation.
The default operational retirement is 2046-09-25. Certificates last 3650 days,
capped at retirement, with a 30-day renewal window. Gateways request their
certificate from Marshall on every daily run, so changing `publicHost` reissues
the Porsche and Audi principals within a day; Marshall reuses a generation whose
principal still matches. OpenSSH CA keys themselves have no embedded expiry.

## Common runtime startup refusal evidence

## SCIM configuration

`Marshall.Scim.Configuration` is the persisted singleton for SCIM enablement,
token digest rotation and runtime identity settings. The Control Room route
`/admin/scim` is administrator-only. The public `/scim/v2` plug rejects every
request until the configuration is enabled and compares bearer credentials
against the stored digest; plaintext tokens are never persisted or logged.

Enabling SCIM archives native teams and starts their retirement workflow.
Disabling SCIM does not reopen managed teams until an administrator performs
explicit ownership handoff. The SCIM machine scenario exercises protected
discovery resources, malformed credentials, English and Arabic Control Room
responses; Hegel lifecycle properties cover duplicate delivery and the
pause-before-delete ordering. Full administrator provisioning and seven-day
clock advancement still require a configured integration environment.

Marshall's common runtime guards reject invalid inference retention, ingress
ports, relocation readiness timeouts and default/Inception image identities
before application startup. The fresh Mix property checks 34 cases in three
shuffled histories with test-build beams.
It requires a specific fixed refusal, no reviewed application/Repo/endpoint/
Bandit startup or surviving Marshall state, private input/path-safe output and
positively calibrated tracing. Valid
default/boundary controls load runtime configuration without starting Marshall.
These local checks establish neither production-release startup nor configured
serving. Production secret/TLS/mail/budget faults, optional integrations,
packaged startup, file replacement and hosted faults remain open. Evidence:
[boot property](repo:marshall/test/marshall/operations/invalid_runtime_boot_property_test.exs)
and [execution review](repo:docs/architecture/reviews/2026-09-29-antithesis-property-audit.md).

## Account Git preferences

Settings defaults are Git username Overalls, Git email noreply@overalls.dev and enabled commit trailers. New machine admission captures identity atomically; cloned machines capture the creating account’s settings. Existing machines without a snapshot retain their configuration. Identity values are not diagnostic metadata.
