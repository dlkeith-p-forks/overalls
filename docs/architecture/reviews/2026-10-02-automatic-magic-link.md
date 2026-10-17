# Automatic magic-link browser sign-in review

Date: 2026-10-02. Decision: [ADR-0131](../decisions/0131-automatic-magic-link-sign-in.md).

## Scope and finding

The former magic-link page required a second click and exposed a remember-browser
choice. The requested browser journey now posts the token automatically with
remember enabled and follows the existing callback's return destination and MFA
decision. The Ash strategy still requires interaction so its authentication
endpoint cannot consume a link through GET. The link page's GET renders a
CSRF-protected form without changing stored authority; its connected LiveView
submits the POST. JavaScript-capable mail scanners can still consume a link.

The existing account action continues to own eligible-domain registration,
single-use token verification, ordered stored-login issuance and remembered
credential generation. The callback still checks the stored login before
establishing the session. No database schema, protocol, deployment placement or
authorization policy changes. ADR-0131 replaces the inherited second-click
requirement in ADR-0066 while carrying forward account lifecycle authority;
ADR-0123's remembered-login MFA and revocation rules remain in force.

## Verification and limits

The focused HTTP flow passed seven tests on this branch, including new, existing
and MFA-enabled accounts, GET token preservation, return routing, a secure
remembered cookie and replay refusal. HTTP tests do not execute the browser's
automatic submission. The `nix build .#checks.x86_64-linux.mfa-login-browser`
run passed its native browser subtest on three colocated Marshall replicas in one
NixOS VM over verified TLS with a virtual WebAuthn authenticator. The script
followed magic links without clicking a sign-in button, checked remembered
cookie issuance, pending MFA, cross-replica revocation and expired-ceremony
refusal; the browser subtest took 25.67 seconds and the VM script 60.07 seconds.
This is a new execution of the updated browser fixture, separate from the
historical native MFA records.

Ruff, Ruff format and ty passed across all Python files; the ADR checker, HLDD
source views and Nix HLDD check passed. Marshall's full `mix precommit` gate
passed on this branch, including its distributed tests and forced Dialyzer check
with zero errors. Production rollout, actual inbox delivery,
JavaScript-capable mail scanner behavior, physical hosts and hardware
authenticators remain unverified.
