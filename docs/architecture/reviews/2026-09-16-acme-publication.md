# ACME issuance and persistent certificate publication

## Scope and architectural impact

This change implements the certificate-management portion of ADR-0030 and adds
ADR-0033 machine evidence. ADR-0032 supplies the selected Route 53 credential
through the existing SSH-derived SecretSpec/SOPS boundary. The accepted decisions
and their rationale remain unchanged; all three remain partially implemented.
The user's instruction to implement the accepted plan authorizes this work.

Implementation evidence:

- [ACME module](../../../nix/domains/system/acme/default.nix): native NixOS ACME issuance,
  explicit Route 53 zone, private systemd credentials, scoped IAM policy artifact,
  publication/retry services and proxy ordering.
- [Client wrapper](../../../nix/domains/system/acme/lego.py): sole validated default AWS profile,
  no ambient/metadata fallback, bounded execution and fixed JSON diagnostics.
- [Publisher](../../../nix/domains/system/acme/publish.py) and
  [atomic bundle helper](../../../nix/domains/system/secrets/prepare.py): trust, hostname,
  lifetime, matching key, custody and actual HAProxy configuration checks;
  persistent publication with fsync and graceful reload.
- [Machine suite](../../../nix/verification/tests/machines/acme-route53/default.nix),
  [certificate fixture](../../../nix/verification/tests/support/acme-fixture.py) and
  [Route 53/DNS fixture](../../../nix/verification/tests/machines/acme-route53/route53.py): actual source-built
  Marshall and HAProxy with Lego, Pebble and cryptographically signed DNS changes.
  Credentials, SSH keys and CA keys are generated privately inside the VM.
- [NixOS guide](../../operations/nixos.md): configuration, private state, operational
  boundaries and separate production-provider acceptance.

## Findings and resolution

1. **High, implementation recovery defect — resolved.** Initial publication used
   `/run`. A reboot discarded the last validated certificate while native issuer
   output could contain a failed or partial replacement. Publication now uses
   private `/var/lib/overalls-certificates` state; files, the prepared directory
   and its namespace change are fsynced before a reload request. Proxy startup
   revalidates that cache even when a new publication attempt fails. No bootstrap
   self-signed certificate can pass the configured CA/name checks.
2. **High, implementation retry defect — resolved.** Comparing only published
   bytes skipped a retry when publication succeeded but the subsequent reload
   failed. The independent publication timer now verifies the certificate actually
   served over TLS and retries a validated reload when needed, even when bytes
   match. A proxy already serving the expected certificate avoids needless
   reloads and retained workers for long-lived WebSockets. Missing/invalid cache still prevents startup. The
   machine suite injects a failed reload and retries without another issuance.
3. **Medium, credential-source and diagnostic boundary — implemented.** The
   client receives a systemd credential and rejects additional AWS profiles or
   credential-process settings. It runs with an explicit environment excluding
   ambient AWS credentials and metadata discovery. Raw client/provider errors
   are discarded. The provider fixture reflects synthetic credentials in its
   denial response; the journal check must still find no credentials or keys.
4. **Medium, verification correction — resolved.** An idle HTTP keep-alive probe
   was unsuitable for proving active connection preservation. HAProxy closes
   idle HTTP connections during graceful shutdown, as described by the
   [HAProxy manual](https://docs.haproxy.org/3.3/configuration.html#idle-close-on-response). The replacement probe opens
   the actual Marshall LiveView WebSocket transport and exchanges heartbeats
   before and after renewal on that same connection. It proves transport
   survival, not an authenticated guest terminal session or cross-node failover.
5. **Medium, explicitly unimplemented acceptance.** Public DNS, actual AWS IAM
   enforcement, real CA issuance, physical power-loss durability and authenticated
   terminal sessions through this NixOS proxy remain open. These do not require
   replacing the accepted design. The reference host, images, native sparse ZFS,
   multi-node guest suites and independent production failure domains also remain
   part of the broader plan.

## Verification

The initial local ACME suite passed in **79.63 seconds**, establishing issuance,
renewal, provider failure and invalid replacement rejection before the persistent
cache and reload-recovery additions. This is not the final-revision acceptance.
The expanded ACME suite passed in **139.95 seconds** with:

- actual DNS issuance, signed Route 53 requests and TXT cleanup;
- a new served certificate and a stable HAProxy master process after renewal;
- successful heartbeats over the same Marshall WebSocket across that reload;
- provider failure preserving the working certificate and readiness;
- an injected failed reload, followed by successful publication/reload retry
  without another issuance;
- wrong-name, mismatched-key, untrusted and expired replacements rejected;
- the same four invalid cached certificates preventing a cold proxy start;
- recovery using the previous persistent cache while issuer output remained bad;
- restored valid issuer output and journal checks excluding synthetic credentials
  and private key material.

The final revision, including the served-certificate check that avoids needless
reloads, passed the full ACME suite again in **131.15 seconds**.

The secret-custody regression suite passed in **111.33 seconds**, including the
actual systemd environment properties, interrupted publication, credential
rotation and retained SSH identity across a NixOS generation switch.

The four-node service-role regression suite passed in **73.35 seconds** after
the common TLS fixture change. It forces KVM and validates actual inner KVM on
Lilly nodes; it does not provision guest VMs. Source package/runtime checks from
the [earlier deployment review](2026-09-16-nixos-releases-and-roles.md) remain
applicable: application source and lockfiles did not change in this phase.

The module configuration check passed, including ACME enablement, required CA
terms, certificate-path ownership and rejection of a root proxy. The pinned
`devenv shell` gates passed: **34 ADRs** and **47 CONTRACTS files / 412 maintained
sources**. These are structural checks, not operational acceptance. `git diff
--check` passed. No Elixir application source changed, so the application
precommit suites were not rerun in this phase.

Intermediate failures were kept separate from passing evidence:

- Python's strict CA validation exposed missing key-usage/identity extensions in
  the shared synthetic CA fixture. Those extensions were added; TLS verification
  was retained throughout. The initial server-side TLS diagnostic was misleading.
- Lego's propagation check resolved the authoritative nameserver through the
  system resolver. The fixture now configures both that resolver and the explicit
  recursive DNS endpoint. DNS validation is enabled in Lego and Pebble.
- The idle HTTP connection test failed as described above and was replaced by a
  WebSocket transport test, without weakening the proxy's reload behavior.

All machine runs use local fixtures and forced hardware acceleration. No live
host, AWS account or production certificate was changed. Tests require the builder
user to access KVM in addition to advertising the relevant Nix feature. The
temporary `nixbld` KVM ACL was removed after all test VMs exited; the original
root/kvm access remains. No permanent builder configuration was changed.

## Remaining work

Run the additional ADR-0033 scenarios and the production-provider acceptance
separately. Preserve private ACME state across real host upgrades/reboots, verify
physical crash recovery, complete image identity checks, and integrate the
reference host configuration. Continue ADR-0031 sparse ZFS implementation and
its logical/physical capacity accounting. ADR-0034 tuning remains proposed until
measured on the intended storage and workload.
