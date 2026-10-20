# Fleet build scheduling review (2026-10-20)

## Scope and architecture impact

Pins [tribuchet](https://github.com/Mic92/tribuchet) `1a1002096f3c1f6d7b32b3ef9822e542b095a948`
and [nix-grpc-store](https://github.com/Mic92/nix-grpc-store)
`17f4ff97a6fdac3c68458a0f15210762eba261ea` as flake inputs following the stable
NixOS input, and enables them on Panterloons and Dungarees through
[`nix/domains/system/fleet-builds.nix`](../../../nix/domains/system/fleet-builds.nix).
This changes build placement, a trust relationship, a significant dependency and
the hosts' Nix package, so [ADR-0248](../decisions/0248-fleet-build-scheduling.md)
supersedes [ADR-0086](../decisions/0086-reciprocal-nix-caches.md), which
remains authoritative for non-participants. The user authorized the topology,
the private mTLS CA and replacing the pair's ssh-ng caches with `grpc://`.

## Findings

1. **Build cycle (resolved by design).** ADR-0086's deadlock came from two
   daemons each listing the other as a builder. Panterloons has no build
   machines (asserted); Dungarees' single `grpc://` builder reaches
   Panterloons' daemon through the direct derivation protocol, which does not
   run the receiver's build hook; tribuchet workers only import. The machine
   check shows delegated builds completing on both workers.
2. **Lock-file name overflow (fixed).** Nix names a per-machine lock file after
   the builder URI. Certificate store paths in the query exceeded `NAME_MAX`
   and made every delegated build fail in the first machine run. The client
   pair now uses nix-grpc-store's default `/run/nix-grpc-store` location and the
   CA a short `/etc` path; the evaluation check bounds the URI length.
3. **Hub outage failed scheduler builds (fixed, upstream follow-up).** With
   the hub socket stopped, tribuchet's attach shim exhausted its reconnects and
   failed the build instead of declining, so Panterloons could not build at
   all, including its own update candidate. The scheduler's external builder
   is now a wrapper that probes the socket and, when it refuses, prints Nix's
   builder ready marker and exits with tribuchet's decline code 222 (an exit
   before the marker is a setup failure), so the patched Nix builds locally; a listening
   socket with a restarting hub still accepts and keeps resubmission. The
   machine check asserts the local fallback with no agent activity. Upstream
   should decline on persistent connect failure in the shim itself.
4. **Trusted pool (accepted risk).** A compromised worker, or a holder of
   Dungarees' grpc key (role `trusted`), can inject outputs into Panterloons'
   store. This equals the `nix-ssh` trust ADR-0067 accepted; global signature
   checks remain for all other substituters. Tribuchet certificates cannot be
   revoked; both CA keys were discarded after issuance, so rotation reissues
   everything.
5. **Experimental Nix feature (accepted risk).** `external-builders` is
   experimental. Tribuchet's uid-range and decline-fallback patches apply to
   the nix-compact 2.34.8 base without conflict, so ADR-0087's compact logs are
   kept. The package rebuilt from source; a Nix bump must re-verify the patches.
6. **Agent socket mode (observation).** Tribuchet agent sockets are `0666`
   under `/run/tribuchet/agents`, by upstream design; the agent accepts only
   leases from the worker. No fleet change; recorded for future review.
7. **Open: placement hints.** Whether `external-builders` honours
   `preferLocalBuild` is unverified; derivations needing `nested-kvm` are
   declined by workers and build locally on Panterloons.

## Validation

- `nix build` of tribuchet, the patched nix-compact, the grpc plugin dispatcher
  and daemon against the stable input.
- `fleet-builds-configuration` evaluation check on the real Panterloons,
  Dungarees and Overalls configurations plus rejected variants.
- `fleet-builds` two-VM machine check (fixture CAs, plain VM network) at the
  final tree: **all 6 subtests passed, test script finished in 135.31s**.
  Topology; four delegated builds spread with agent activity on both workers;
  a scheduler-local build through the hub; unsigned grpc substitution in each
  direction; refusals of `build-mallory` (`no access rule matches`), the
  read-only peer's tunnel and unsigned import (`may not call Connect`,
  `may not call AddMultipleToStore`) and a rogue-CA worker certificate; local
  fallback with the hub stopped (no agent activity) and, with the scheduler's
  grpc daemon stopped, a peer-local build after 27 s (101 s before the
  `connect-timeout=5` URI parameter).
- Panterloons and Dungarees toplevel builds; Salopettes evaluates identically
  and Overalls' Nix settings, packages, services and `/etc` entries are
  unchanged.

## Remaining gaps

No deployment receipt yet: after activation, record a delegated build from
Dungarees, `/workers` on Panterloons listing both workers and grpc substitution
in each direction. The machine check does not run over the tailnet.
