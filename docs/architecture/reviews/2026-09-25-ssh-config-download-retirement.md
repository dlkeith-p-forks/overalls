# SSH configuration download retirement

Date: 2026-09-25

## Scope and architecture impact

The user authorized removal of the Marshall web SSH configuration download and
its generation while retaining the installation script. The machine connection
controls keep the installation and SSH commands. The retired
`GET /machines/:id/ssh-config` endpoint now returns the ordinary unmatched-route
404, including for authenticated owners. There is no redirect or replacement
attachment endpoint, and already-downloaded client files are not modified.

This retires a legacy web delivery surface and its standard, Inception and nested
renderers. No persistence, shared wire protocol, Cedar authorization, gateway
key-discovery or SSH admission behavior changes. The public `/bin/` installer,
artifact delivery and Lyra local wildcard configuration remain supported under
[ADR-0110](../decisions/0110-cedar-guest-ssh-accounts.md) and
[ADR-0118](../decisions/0118-installer-management-ssh-trust.md).

## Decisions and contracts

[ADR-0047](../decisions/0047-audi-ingress-and-authoritative-dns.md),
[ADR-0085](../decisions/0085-inception-public-ingress.md) and
[ADR-0096](../decisions/0096-lyra-developer-ssh.md) already have superseding
records. Their historical rationale and implementation status remain intact;
retirement notes distinguish previous download evidence from current behavior.
ADR-0110's implementation evidence now describes the retained installer path.
No current accepted account, ingress or trust decision is replaced.

Removed controller and renderer contracts applied only to the retired feature.
The [web contract](../../../marshall/lib/marshall_web/CONTRACTS) now specifies
installer-based setup and the absence of profile downloads. Shared endpoint
reads and their authorization contracts remain in place.

## Implementation and verification

The [router](../../../marshall/lib/marshall_web/router.ex) and
[workspace component](../../../marshall/lib/marshall_web/components/workspace_components.ex)
remove the route and link; the dedicated controller and renderer are deleted.
[Machine page tests](../../../marshall/test/marshall_web/machines_live_test.exs)
cover retained connection controls and anonymous/owner requests to the retired
endpoint. Existing [installer tests](../../../marshall/test/marshall_web/controllers/overalls_controller_test.exs)
cover public delivery, digest verification and management trust behavior.

The [native OpenSSH check](../../../nix/verification/tests/machines/audi-openssh/default.nix)
uses explicit test-only profiles while continuing to execute real OpenSSH and
Lyra Rust HTTPS lookup. Its assertions retain independent gateway/guest trust,
stale-key refusal, nested connections, and failed/oversized/untrusted discovery.
The [fleet operator fixture](../../../nix/verification/tests/machines/fleet/operator.exs)
uses the same standard profile template with a validated endpoint label and fixed
fixture origins. No production renderer remains. These fixtures are not a new
public configuration API and do not prove production fleet acceptance.

The fixture keys now have empty comments, matching the host-key endpoint's
canonical three-field lines required by Lyra's strict parser. The previous
fixture appended `root@client`, which caused the first real lookup to fail.
The nested workload fixture also uses the test HTTPS listener's port 4443.
Lyra's host-key contract now names the retained command rather than the retired
Marshall renderer; its implementation and the installer are unchanged.

Validation in the isolated worktree:

- The focused machine-page and installer tests passed all 39 cases.
- Marshall's complete test run passed 967 checks (74 properties, 893 tests),
  including distributed tests; two environment-specific cases were excluded.
- The native OpenSSH check passed all positive and negative scenarios in 22.21s:
  `/nix/store/38vpn8p891364285l78cyvc7lcq184hm-vm-test-run-overalls-audi-openssh`.
- `prek run --all-files` passed ruff formatting/linting, ty and all application
  logging gates. The native Nix check also checked its composed Python driver.
- ADR validation and contract syntax/discovery checks passed. Semantic review
  covered retired renderer/controller callers, retained installer controls and
  both test fixture consumers; no unresolved contract violations were found.
- `audi-relocation-fleet.drvPath` evaluated successfully. For a representative
  dynamic VM label, the fleet template matched the former renderer byte-for-byte;
  the operator source parsed successfully. The full fleet VM test was not rerun.

Marshall `mix precommit` passed in `devenv shell`, including pinned runtime,
compiler, formatting, browser checks, TypeScript and forced Dialyzer. Dialyzer
reported zero errors, skipped findings or unnecessary exclusions.

After rebasing onto main's cloning UI change (`7cd5202f`), compilation and
format checks passed. All 54 focused integration checks (3 properties, 51 tests)
passed across the machine views, clone components/state machine and installer.
Forced Dialyzer passed again with zero errors or exclusions. The native OpenSSH
derivation remained identical to the passing result above. The final diff
preserves the installer and Lyra setup implementations unchanged.

## Remaining limits

Lyra's existing lack of a nested Inception setup path remains unchanged. Retiring
the legacy download does not implement that client capability. Full fleet and
production deployment acceptance are separate from this bounded removal.
