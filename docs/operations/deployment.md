# Deployment

Deploy Marshall and Lilly with the [NixOS modules and machine configurations](nixos.md)
under [ADR-0036](../architecture/decisions/0036-automatic-host-updates.md), which retains
ADR-0030's deployment decisions and adds automatic pre-switch migration. Enable
Marshall, Lilly, or both; the service modules manage runtime configuration,
privileges, resource limits, TLS and independently supervised guests.

The manual `deploy/` examples have been retired. The
[Nix layout guide](../../nix/README.md) identifies the maintained sources and the
[test catalog](../../nix/verification/tests/README.md) lists verification commands.

## Prepare a deployment

Supply reviewed hardware/network configuration, persistent SSH host identities,
private encrypted secret documents, public DNS/backend trust, PostgreSQL
and SMTP settings. Preserve the existing host's storage and identity during
service activation; disk installation is a separate explicit operation.

Declare 1–100 distinct Marshall instances with the shared database, signing
secrets and Cloak keyring. Budget each Repo pool plus its Oban notifier, with ten
operator/migration connections for manual deployment. Automatic updates reserve
another two connections per declared replica. [ADR-0048](../architecture/decisions/0048-single-host-service-deployment.md) permits
an explicitly nonredundant one-instance deployment with local PostgreSQL.
The configured count and limits do not establish
physical failure domains or throughput. Production resilience requires independent
hosts and a tested database availability/recovery plan.

Use HAProxy public TLS termination with verified TLS to each Marshall backend,
including hostname verification for `/health/ready`. Apply the module's Route 53
ACME and certificate-publication workflow. Configure database TLS to a writable
primary and private SMTP delivery as described in the NixOS guide. Keep private
configuration outside source, build artifacts and the Nix store.

Set `services.marshall.defaultImageId` to a registered, enabled image digest
(`sha256:` followed by 64 lowercase hexadecimal characters) to choose the default
for SSH creation and the browser. Manual releases use `MARSHALL_DEFAULT_IMAGE_ID`;
invalid values fail startup. The NixOS option defaults to `null` and clears the
environment default. Image availability and capacity are still checked by Ash
at admission. Omitted resource sizes round upward to image minimums in whole
MiB/GiB; explicit sizes are preserved and validated.

For Porsche gateway credential provisioning, rotation and disabling, follow the
[operator workflow](porsche-operations.md).

## Build and rollout

Run the project gates and [NixOS checks](../../nix/verification/tests/README.md#run-checks), then
build the reviewed machine configuration. Follow the NixOS guide for installation,
secret delivery and the explicit serialized migration command. Serving services
never run migrations at startup.

For independent automatic updates, follow the [updater configuration](nixos.md#automatic-host-updates).
It builds an immutable revision, checks staged secrets, applies compatible migrations,
switches and verifies local health. It does not coordinate restarts across hosts.

For a compatible Marshall update, stage the configuration, apply compatible
migrations, take one backend out of rotation, restart it, wait for readiness and
restore traffic. Include any surge instance in the replica/connection budget.
Incompatible schema changes require a coordinated upgrade; selecting an older
NixOS generation does not roll back database changes. Retain required Cloak
keys for existing ciphertext and backups during rotation.

For Lilly updates, preserve its durable state and bound host identity. A daemon
restart leaves independently supervised guests running. Use the
[host drain workflow](host-maintenance.md) before host maintenance or reboot;
stopping the VM slice is not a substitute for confirmed cleanup. Follow
[storage rollout ordering](storage-capacity.md) when enabling native ZFS pools.

## Optional offline release exports

The existing export helper remains useful for transferring source-built releases
and their complete runtime closures into an offline Nix store:

```sh
devenv shell
./scripts/package_release.sh marshall
./scripts/package_release.sh lilly
```

Each command verifies the selected release and writes `artifacts/APP`,
`APP.store-path`, `APP.nar` and `APP.nar.sha256`. Transfer through a trusted
administrative channel, verify the checksum and import with `nix-store --import`.
Configure and activate services through NixOS. A checksum identifies contents,
not the publisher; release exports alone are not a complete machine closure.

## Acceptance boundaries

The NixOS suites exercise source-built packages and actual modules, including
three Marshall machines, two nested-KVM Lilly machines and real Firecracker
guests. Local provider fixtures do not establish live AWS/CA/SMTP acceptance;
virtual storage timings do not establish physical performance.

The
[database recovery guide](database-recovery.md) covers fenced promotion and isolated
restoration; a historical backup cannot become authoritative for surviving guests
without reconciliation. The [completion audit](../architecture/reviews/2026-09-16-plan-completion-audit.md)
tracks remaining existing-host inputs and physical/deployment acceptance.
