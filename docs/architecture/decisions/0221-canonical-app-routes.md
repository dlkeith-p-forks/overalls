# ADR-0221: Canonical `overalls://` app routes

- ID: ADR-0221
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: protocol, Marshall, Mila
- Supersedes: none
- Superseded by: none

## Context

Results, approval pages and (later) notifications need to open a matching Mila
screen. Without one canonical form, Marshall, Porsche and Mila would each invent
link syntax, and a link could carry more than navigation.

## Decision

1. `OverallsProtocol.AppRoute` defines `overalls://HOST[:PORT]/PATH` over a
   closed table mirroring Marshall's browser routes: `/machines`,
   `/machines/:id[/info|/web]`, `/machines/:id/threads/:tid`,
   `/machines/:id/terminals/:sid`, `/threads`, `/threads/:id`,
   `/launch?source=URL` (validated as a workspace source), `/ssh/approved?session=UUID`
   and `/settings`.
2. Parsing accepts only DNS hosts, canonical UUIDs and closed query keys within
   2 KiB; it never creates atoms or raises. Formatting is the parser's inverse.
3. Marshall emits a link only when it parses back to the same route for the
   endpoint's public host (`Marshall.AppRoutes.link/1`); links name public
   identifiers only, never tokens or approval paths.
4. Mila parses links with a Dart port sharing the same fixture corpus, and
   following a link is navigation only: an unknown deployment lands on the
   deployment list and a signed-out deployment reaches only its sign-in
   screen. Platform deep linking stays disabled; links reach Mila's router
   through its own platform channel (iOS scene delegate, Android VIEW intent,
   Linux `x-scheme-handler/overalls` desktop entry).

Authorization: the approved Mila plan (2026-10-18).

## Alternatives

- **HTTPS universal/app links.** Rejected for v1: they need per-deployment
  association files that self-hosted Marshalls cannot sign for the store app.
- **Flutter's built-in deep linking.** Rejected: it routes only the path and
  would drop the deployment host the route depends on.

## Consequences

Every new browser route that Mila should open needs an AppRoute entry and a
fixture row in the same change.

## Invariants and verification

- `format(parse(link)) == link` for every accepted link, and arbitrary input
  never raises (Hegel properties in Elixir and Dart).
- Elixir and Dart agree on every row of `protocol/test/fixtures/app_routes.json`.
- Links to unknown or signed-out deployments never open a deployment page
  (Dart Hegel properties; widget tests over the platform link stream).

## Implementation evidence

- [`protocol/lib/overalls_protocol/app_route.ex`](../../../protocol/lib/overalls_protocol/app_route.ex), [`protocol/test/app_route_test.exs`](../../../protocol/test/app_route_test.exs),
  [`protocol/test/fixtures/app_routes.json`](../../../protocol/test/fixtures/app_routes.json) and codecs obligation I7.
- [`marshall/lib/marshall/app_routes.ex`](../../../marshall/lib/marshall/app_routes.ex) with [`marshall/test/marshall/app_routes_test.exs`](../../../marshall/test/marshall/app_routes_test.exs);
  `ls`/`show` add `route` in [`marshall/lib/marshall/ssh/commands.ex`](../../../marshall/lib/marshall/ssh/commands.ex).
- [`mila/packages/mila_core/lib/src/app_route.dart`](../../../mila/packages/mila_core/lib/src/app_route.dart) and `test/app_route_test.dart`;
  [`mila/app/lib/features/routes.dart`](../../../mila/app/lib/features/routes.dart), `test/link_target_test.dart` and
  `test/incoming_link_test.dart`.
- Platform delivery: `mila/app/ios/Runner/{AppDelegate.swift,Info.plist}`,
  `mila/app/android/app/src/main/{AndroidManifest.xml,kotlin/…/MainActivity.kt}`,
  and the desktop item in [`nix/domains/artifacts/mila/default.nix`](../../../nix/domains/artifacts/mila/default.nix).

Gaps: the Marshall tests have not run (Marshall does not currently compile on
this branch's base); the "Open Mila" link on the SSH approval page and push
payload routes are not implemented; native link delivery is uncompiled.

## Open questions

None.

## Related decisions

[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0222](0222-porsche-client-commands.md),
[ADR-0224](0224-susan-push-relay.md).
