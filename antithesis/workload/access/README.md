# Browser authority workload

The `access` template drives three real Marshall HTTPS/LiveView journeys. It
requires both Marshall releases, the shared PostgreSQL SELECT oracle, the
synthetic SMTP TLS fixture (`compose.smtp.yaml`), and the private access fixture
created by Marshall's closed operator. Only the fixture-private message API
provides accepted SMTP DATA; the durable receipt ledger remains content-free.
The SMTP overlay mounts its runtime CA and password into both Marshall replicas
and selects authenticated implicit TLS for their mail transport.

`singleton_driver_magic_preview.py` uses the fixture's MFA-enrolled target.
It requests a link, checks two GET previews against stored token and browser
credential state, submits Marshall's rendered CSRF form, retries that token on
the second release, and checks pending MFA on a copied session context
against ADR-0160: the unverified login's ordinary `/overview` read on the second
release is served without verification or a new stored login, while a real
AccountLive (/settings) passkey rename there is refused with an unchanged passkey
inventory. A server error or missing reply leaves either check unexercised.
The Control room administrator step-up redirect is not exercised because the
target is not a fixture administrator. A same-login WebAuthn verification runs
only when the actual browser URL matches the fixture RP origin.

`serial_driver_remember_replay.py` creates a fresh no-MFA synthetic user through
the public magic-link flow. It demonstrates a remembered exchange on the second
release, signs out the original credential on the first, then replays a private
copy and compares exact stored login and remember JTI sets.

`singleton_driver_stale_admin.py` logs fixture admin B in and verifies its
passkey on the matching RP origin, copies only its signed session into a context
pinned to B, and mounts `/admin/users` on B. It proves one authorized `set-role`
event wrote a target/audit pair, invokes the closed operator's Ash demotion,
then sends a stale event and compares target/audit inventory. Cookie copying
tests session transfer across the releases; it does not establish ordinary
same-origin browser failover. No template observes guest bytes or physical VM
effects.

Transport loss, unavailable SQL, evicted SMTP DATA, missing fixture identity,
and unacknowledged LiveView events leave the corresponding assertion
unexercised. The template is source instrumentation until a selected Compose
graph and hosted run establish actual reachability and fault coverage.
