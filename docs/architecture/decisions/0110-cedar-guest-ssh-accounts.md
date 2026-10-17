# ADR-0110: Cedar-authorized guest SSH accounts

- ID: ADR-0110
- Date: 2026-09-23
- Status: superseded
- Implementation: partial
- Components: Marshall, Audi, Lilly, Lyra, NixOS guest, Ubuntu guest
- Supersedes: ADR-0093, ADR-0096
- Superseded by: ADR-0115

## Context

[ADR-0115](0115-ssh-roster-boot-authority.md) replaces only the completed-start
requirement for roster bootstrap. All other decisions and rationale below are
retained.

ADR-0093 pinned one Porsche session key into a VM disk for root SSH. A new VM
without such a key has no guest SSH listener, while cloning a keyed disk copies
its SSH authority. The wildcard Lyra profile in ADR-0096 still selects root.
The user requires current Marshall SSH keys and Cedar write permission to
authorize separate guest accounts, with active revocation and durable login
evidence. The user also requires an email-derived guest username and home.

## Decision

The authenticated Marshall email local part, lowercased, is the Linux guest
username. Marshall accepts only local parts that can be used exactly as safe
Linux usernames; it reserves past usernames so a different account cannot gain
an old home. Each account incarnation receives a stable, never-reused guest UID.
An email change creates a fresh account and UID; the old login is disabled and
its home remains on disk. Cedar revocation likewise disables login and retains
the home. Writer access includes passwordless sudo, so homes are not a security
boundary against other authorized writers.

The installer detects the local operating-system account, proves possession of
one Marshall-registered SSH key, and obtains the associated guest username from
Marshall. It writes that username and matching identity into its managed
wildcard SSH profile. The local username is never assumed to be the guest name.
The user need not provide an email address or domain to install or connect.
The nested Audi SSH process must offer that same selected key explicitly with
other identities disabled; it cannot depend on the local machine's default key
names or agent ordering. For agent-only keys, the CLI keeps the selected public
key as its `IdentityFile` selector and carries the Porsche proof connection's
effective `IdentityAgent` socket into its isolated Audi SSH subprocess. A
quoted socket path containing spaces must survive intact. For encrypted private
key files, setup may match their bounded public-key sibling, and macOS SSH may
retrieve a passphrase from Keychain or prompt at the terminal.

On standard NixOS and Ubuntu guests, a Rust `overalls-ssh-authorize` service
reconciles local accounts and mode-0700 homes from a versioned, VM-bound
Marshall roster. sshd admits only public keys returned by its unprivileged
AuthorizedKeysCommand callback after Marshall verifies the offered key, guest
username, live placement, existing Audi admission and current Cedar write
permission. Root login, guest key files, password authentication and forwarding
are disabled. The helper's Rust TLS client loads a bounded guest CA bundle,
uses a fixed private origin, disables proxies and redirects, and enforces a
short deadline and bounded response reads. NixOS permits managed accounts to
survive activation and copies the callback to a root-owned `/run` path before
sshd starts, satisfying OpenSSH's executable path check. Both guest images
publish a boot-local success marker after roster reconciliation; the listener
starts only when that marker exists, and a later successful refresh can open
the listener after an early authority outage.

The private authority uses `ssh.integration.internal`, a reserved host covered
by the existing `*.integration.internal` fleet certificate. The two-label
`*.internal` wildcard does not match `ssh.internal` under OpenSSL hostname
verification. Audi reserves the `ssh` integration label, routes that hostname
to Ziggy's SSH relay, and permits Customer guests to reach only this private
service. The host firewall admits only the fixed DNS/TLS address and its
established replies; Marshall still checks every decision against the current
physical binding.

Audi retains independent five-second authority leases and must stop active SSH
streams within five seconds of key or share revocation. AuthorizedKeysCommand
eligibility is not recorded as a successful login. A post-authentication guest
event records a guest-reported login with key, account and VM binding in Marshall's
durable audit trail. VM root can forge that report. Marshall's key-linked outer
session records admission, and Audi's host-controlled stream-open event records
a successful connector handoff; neither alone proves guest user login.
Structured diagnostics use
fixed, reviewed event schemas and exclude
keys, credentials, command arguments and terminal data.

The user's implementation instruction authorizes this replacement. There is no
compatibility path for provision-time root keys on standard guest images.
The old nullable VM key column remains temporarily inert so pre-switch
migrations remain readable by the prior release during automatic rollout;
physical removal is a later coordinated schema cleanup.

## Alternatives

The prior disk-pinned root key cannot represent multiple users or current Cedar
membership. Deriving the guest account from the local computer username fails
when it differs from the Marshall email. Hashing the Marshall UUID into a guest
name avoids email rename effects but does not meet the requested username.

## Consequences

The guest must reach a private, authenticated roster and key-decision service;
its unavailability denies new logins. Home data survives revocation and email
change until explicit VM deletion. An email change requires Lyra to refresh its
managed SSH profile. Existing pre-Cedar VM disks, with or without a
provision-time root key, need replacement or migration before they can use the
Cedar guest SSH path.
During relocation, the physically current destination may fetch its roster
before guest readiness is confirmed, so it can start sshd. Key authorization
and login remain gated on confirmed readiness. The roster request still checks
the exact host, placement, execution epoch and completed start operation.

## Invariants and verification

- Email local parts must round-trip to exact safe guest names; retired names and
  UIDs never transfer between users.
- NixOS and Ubuntu machine tests must prove two users have separate homes,
  restart and relocation retain ownership, and both key and Cedar revocation
  deny new logins and close existing Audi streams within five seconds.
- After relocation, the unchanged strict SSH profile must reconnect and run
  `whoami`, `pwd` and `ls` in the expected user home, read a file written
  before the move, and produce a login audit row bound to the destination.
- A user journey machine test must create a fresh Firecracker VM through Porsche,
  configure the Overalls CLI under a local account, and reach an interactive
  guest shell with the expected email-derived username and writable home. It
  must also execute `whoami` and `pwd` as ordinary SSH remote commands, with a
  registered private key held under a nondefault local filename.
- Eligibility events cannot masquerade as post-authentication login events.
- Rust unit and Hegel property tests cover parsing, reconciliation, conflicts,
  key matching, stale rosters and fail-closed responses.
- Login, authorization and account outcome events follow outer commits and omit
  secret material.

## Implementation evidence

The [guest username parser](../../../marshall/lib/marshall/accounts/guest_username.ex)
and [email validation](../../../marshall/lib/marshall/accounts/eligible_email.ex)
enforce the first account-name admission rule, with focused
[tests](../../../marshall/test/marshall/accounts/guest_username_test.exs).
The [guest account resource](../../../marshall/lib/marshall/accounts/guest_account.ex)
and [allocation coordinator](../../../marshall/lib/marshall/accounts/guest_accounts.ex)
reserve names and UIDs. The Rust
[helper](../../../lyra/src/bin/overalls-ssh-authorize.rs) validates and reconciles
trusted account rosters, with unit and Hegel coverage. The internal
[guest key decision](../../../marshall/lib/marshall/ssh/guest_access.ex) checks a
trusted binding, key, account, Audi session and Cedar write access. The
[private Audi frontend](../../../audi/lib/audi/private/front.ex) and
[Ziggy relay](../../../ziggy/lib/ziggy/http.ex) carry the host-derived binding.
The [NixOS guest](../../../nix/packages/guest/default.nix) and
[Ubuntu guest](../../../nix/packages/guest/ubuntu/default.nix) configure sshd,
PAM, roster sync and account homes. The
NixOS sudo configuration includes the reconciler's policy directory. Managed
policy filenames use the stable UID so sudo also loads policies for names with
dots; reconciliation removes the legacy filename and retirement removes both.
Ubuntu's required package set and authenticated archive lock explicitly include
sudo and sudo-common, which supplies the sudoers.d include. The native terminal
scenario checks passwordless sudo from the reconciled personal account.
The
[Lyra installer](../../../lyra/src/ssh_config.rs) resolves the authenticated
account and passes its selected key to the [outer proxy](../../../lyra/src/proxy.rs),
while its [native HTTPS client](../../../lyra/src/http.rs) bounds
current Audi host-key lookup and update/agent responses without a shell HTTP
subprocess. The installer selects encrypted file keys through their `.pub`
sibling and preserves the exact agent-only public key; the proxy obtains the
effective Porsche `IdentityAgent` through OpenSSH configuration evaluation and
sets that socket only on its isolated child process. The probe includes the
Porsche proof command so `Match command` rules apply; direct, relative,
tilde/token-expanded, environment-variable, inherited and disabled agent forms
are interpreted without copying socket paths into diagnostics. Native macOS
execution remains to be verified. The legacy per-VM profile download and Marshall
renderer were [retired](../reviews/2026-09-25-ssh-config-download-retirement.md); the installer and Lyra's local
wildcard configuration remain the supported setup path. Marshall persists guest-reported login rows
through
[GuestLogin](../../../marshall/lib/marshall/ssh/guest_login.ex), while Audi's
session rows are the trusted connectivity audit. The
[private-network machine test](../../../nix/tests/machines/private-services/driver.py)
proves the Customer DNS/TLS fence. The
[Audi fleet scenario](../../../nix/tests/machines/fleet/scenarios/audi.py) proves
native per-user SSH, separate homes, durable login rows, key and share
revocation, and live stream closure on NixOS and Ubuntu guest images.
The [user SSH journey scenario](../../../nix/tests/machines/fleet/scenarios/user-ssh-journey.py)
checks Porsche key registration and VM creation through to Overalls CLI setup
and an interactive shell on a fresh guest. The
[guest access implementation](../../../marshall/lib/marshall/ssh/guest_access.ex)
separates physical roster bootstrap from readiness-gated key decisions.
The authorized [VM view](../../../marshall/lib/marshall/compute/views.ex) exposes
the stable `ssh_host` separately from its physical `host`, so Porsche users can
connect without reconstructing a database label.

## Open questions

The post-authentication PAM report is generated inside a sudo-capable guest and
therefore cannot provide tamper-proof proof of login independent of the trusted
Audi session. The audit API must continue labeling it as guest-reported.

## Related decisions

[ADR-0047](0047-audi-ingress-and-authoritative-dns.md),
[ADR-0093](0093-audi-mediated-guest-ssh.md), and
[ADR-0096](0096-lyra-developer-ssh.md). The
[foundation review](../reviews/2026-09-23-cedar-guest-ssh-foundation.md) records
the initial integration boundaries. The
[integration review](../reviews/2026-09-23-cedar-guest-ssh-integration.md) assesses
the connected implementation and acceptance gates.
