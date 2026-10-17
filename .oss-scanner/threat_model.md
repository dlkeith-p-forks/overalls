# Overalls threat model

## What Overalls does

Overalls is a self-hosted platform for development machines and the AI agents
that work on them. Marshall is the control plane: it owns accounts, teams,
authorization, machine lifecycle, scheduling, durable agent threads and model
work. Lilly runs on execution hosts and owns host-local storage, networking and
Firecracker guest processes. Audi provides public and private ingress, Porsche
provides authenticated SSH management, Brady filters and caches guest egress,
Enrico maintains bounded Git mirrors, Galileo forwards named integrations, and
Ziggy proxies model work while keeping provider credentials outside guests.
The Protocol library defines the authenticated wire schemas. Lyra and the guest
images implement the guest-side trust, workspace, SSH and agent boundaries.

The project is intended to run on infrastructure controlled by its operator.
Operator configuration, deployment credentials, image sources and the
operator's deliberate authorization policy are trusted. Users, guests,
providers, upstream integrations and network peers are not trusted merely
because they can connect to a configured service.

## Trust boundaries and untrusted input

Treat these as attacker-controlled unless a specific authorization check proves
otherwise:

* browser HTTP, LiveView/WebSocket, API, Control and SSH requests;
* account, team, sharing, machine, thread, prompt, skill and terminal fields;
* guest filesystem contents, workspace repositories, command output and agent
  tool results;
* image manifests, boot metadata, archive members, Git objects and repository
  names supplied through supported workflows;
* public HTTP/HTTPS, DNS, Git, SMTP, model-provider and named-integration
  responses;
* reconnects, dropped replies, duplicate requests, stale credentials and
  messages from old machine or execution generations; and
* data crossing Marshall, Lilly, Audi, Porsche, Brady, Enrico, Galileo, Ziggy,
  Protocol and Lyra process boundaries.

The most important boundaries are current identity and Cedar authorization,
authenticated transport, request and generation fencing, host command custody,
Firecracker/jailer confinement, guest network policy, ZFS ownership, secret
delivery and recovery after process, host or database failure. A successful
database commit or application receipt does not by itself prove a physical
guest or host effect; reports should preserve that distinction.

## Components to prioritize

Prioritize Marshall authorization and lifecycle actions, durable thread and
agent state, Control and Protocol decoders, Lilly hostd/jailer/Firecracker,
guest networking and storage, Audi public/private ingress, Porsche SSH command
dispatch, Brady destination validation and cache isolation, Enrico mirror
authorization and cleanup, Galileo credential forwarding, Ziggy provider
selection and credential custody, and Lyra guest trust/workspace/agent code.

Follow data into shared dependencies when an issue is reachable through one of
those supported interfaces. Pay particular attention to cross-tenant or
cross-team reads and writes, stale or replayed authority, command or path
injection, SSRF, archive traversal, secret disclosure, unsafe deserialization,
protocol confusion, resource accounting, concurrent lifecycle races and
failure recovery.

Build-only helpers, test fixtures, synthetic Antithesis adapters, generated
documentation, local development commands and intentionally public example
credentials are lower priority unless they create a path into a supported
deployment. Do not treat the scanner's Dockerfile or Nix build environment as
the production trust boundary.

## How to exercise the source

The checkout is at `/src` and retains its Git history, pinned flake inputs,
Nix store and release closures. The image builds the currently compilable
Lilly, Audi, Brady, Enrico, Galileo, Porsche and Ziggy releases. Their source
tests are under each component's `test/` directory; shared Protocol tests are
under `protocol/test/`, and Rust guest/host tests are under `lyra/tests/` and
the relevant `native/` directories.

Use bounded existing tests or small local reproducers with sanitized fixtures.
Do not require production PostgreSQL, host credentials, provider keys, live
guests, external services or Internet access. A test that only demonstrates a
unit failure, a missing optional native prerequisite or a controlled denial is
not evidence of a runtime vulnerability without a supported attack path.

The current source drop has a known build limitation: the Marshall release
references missing generation helpers in `MarshallWeb.ThreadsLive`. That is a
qualification/build issue and should be reported separately from a security
finding; do not infer that Marshall's unbuilt release has passed validation.

## Severity guidance

Critical findings include practical remote code execution, guest-to-host or
guest-to-guest escape, arbitrary control of another tenant's machine, or
exfiltration of provider or deployment credentials across an authorization
boundary.

High findings include authentication or authorization bypass, stale/revoked
authority that still grants machine, terminal, SSH, workspace or integration
access, cross-tenant data exposure, command/path injection with meaningful
impact, secret disclosure, unsafe image or archive handling, and remotely
triggerable memory or protocol-safety failures.

Medium findings include realistic scoped information disclosure, privilege
expansion requiring a limited but supported credential, exploitable request or
resource-accounting races, and denial of service with meaningful impact on a
tenant or service. Low findings include unlikely operator misuse, test-only
failures, unreachable defensive assertions, and clean failures without a
security consequence. Pure denial of service and third-party deployment issues
are outside the project's published security scope unless the report shows a
supported security impact.

## Report and patch expectations

Reports should identify the scanned commit, attacker capability, entry point,
authorization state, affected component and exact path to impact. Include a
deterministic reproducer, expected versus observed behavior, security impact,
and a focused proposed patch with a regression test where possible. Separate
dependency findings from Overalls defects and explain reachability. Do not
include real credentials, tokens, terminal bytes, user payloads or private
deployment data in reproducers or diagnostics.
