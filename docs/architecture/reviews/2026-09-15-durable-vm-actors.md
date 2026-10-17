# Durable VM actors and physical host ownership review

## Scope and evidence

Review of executable Lilly startup, actors, physical outcome journals, launch
attempts, admission readiness and deletion retirement. The authorized platform
plan supplies scope. ADR-0017 refines ADR-0016 without replacing its generation,
transaction, fencing or crash-budget decisions. Also affects ADRs 0004–0006,
0009, 0013 and 0015.

## Findings

- **High, corrected implementation gap:** caller-selected state locks could allow
  duplicate physical owners. Fixed global ownership, private persistent binding,
  machine identity, KVM probing, UID/GID checks and unknown-unit fencing now precede
  executable sessions. External NSS allocation still requires operator reservation.
- **High, corrected implementation gap:** accepting v1 inventory could reserve work
  on a receipt-only consumer. Provision/start now require authenticated v2 readiness;
  reports on v1 cannot assert it. Existing v1 receipt compatibility is exercised
  using work admitted before the v1 connection.
- **High, corrected implementation gap:** repeating starts after runtime death could
  bypass Marshall's crash budget. Durable launch-attempt markers and generation
  fencing prevent a second start of the same generation. A proven running generation
  in the journal distinguishes a crash from initial execution failure.
- **High, corrected implementation gap:** losing outcomes or accepting a stale worker
  result could release incorrect reservations. Journal persistence precedes delivery,
  stable IDs/sequences survive restart, acknowledgements match current IDs, and
  completed tasks recheck the current durable command before publishing.
- **Medium, corrected implementation gap:** lifetime deleted directories could reach
  active collection limits. Confirmed deletion removes pool directories, and only
  acknowledged current deletion retires command files/actors. Identity tombstones
  remain. Bound their lifetime storage with a future replay-safe policy.
- **Open platform requirements:** user sharing, remote single-writer terminal,
  retained telemetry, protected enrollment/drain and deployment/load acceptance.
  These remain documented unimplemented requirements, not completed capabilities.

## Verification

- Marshall precommit passed: 91 cases (85 tests, 6 properties), including seven
  three-node cases. Dialyzer passed with its unchanged single upstream
  AshAuthenticationPhoenix typespec exclusion and no unused exclusions.
- Lilly precommit passed: 64 cases (49 tests, 15 properties), no Dialyzer exclusions.
  Protocol precommit passed: 14 cases (7 tests, 7 properties), no exclusions.
- Four opt-in Linux/ext4 runtime/TLS cases passed, including v1 receipt compatibility
  and rejection of new admission to a receipt-only host. Combined: 173 cases,
  comprising 145 tests and 28 properties. These counts exclude manual KVM checks.
- A real HTTPS/KVM run passed three profile VM provisions and public HTTPS, rejected
  a competing runtime with a different state directory, preserved all three VMM PIDs and
  the guest console across hard Lilly process death, retained disk content through stop/start,
  enforced three automatic crash restarts followed by failure, recovered with an
  explicit start, fenced on credential revocation, recovered with rotation, and
  archived/deallocated all guests only after confirmed deletion. All actors retired.
- The crash harness initially used systemd auxiliary-process signalling, which the
  local systemd rejected with `Invalid argument` for the nested jailer cgroup.
  It now signals the tracked service main process to cause an unexpected VM exit;
  physical-empty reconciliation still gates all release/recovery. This changes the
  injected fault, not the production lifecycle implementation. Failed fixtures were
  physically cleaned before their database rows were removed.
- The separate three-guest jailed KVM smoke passed confinement, root TTY, public
  DNS/HTTPS, six VM-to-VM denial paths, host/private denial, spoof/VLAN/IPv6 counters,
  persistent stop/start, allocation credit, missing-disk rejection, delayed-launch
  fencing and cleanup. It removed its units, mounts, disks, TAPs and nftables state.
- The independent Lilly production release rebuilt and evaluated its pinned Elixir
  1.20.4 runtime and x86-64 inventory successfully.
- Original-file hash audit found no missing original files and no new unrelated
  changes. The original 46 staged relocations and existing application work remain.

The final harness revision passed all three VMM identity checks and exact
generation/retry-count increments. It completed credential recovery, all deletions,
actor retirement and fixture cleanup with exit status zero. The host returned to
its prior inactive slice state; the fixed private lock inode remains intentionally.
The ADR validator passes 17 records and local links; it does not establish runtime
safety.

## Follow-up and limits

One physical KVM host is available for this evidence. It cannot establish cross-host
isolation or operational failover. Three-node database tests cover shared-authority
races, not 100-node production capacity. Keep these limits explicit until measured.
