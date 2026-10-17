# control-bound-credential-revalidated

Priority: P0. Confidence: high in the intended contract; no hosted run. Type: Safety, with a recovery reach anchor.

## Guarantee and proposed assertions

After a service credential is rotated, revoked or expires, an already welcomed socket cannot use its cached upgrade principal to authorize a new domain effect. Use `Always(no_effect_after_credential_fence, "Bound control sockets revalidate current credentials before each domain effect")` on every pre/post-fence exchange. `Reachable("Bound control credential rotation is refused on the next request")` marks a witnessed refusal after the committed rotation. Both planned literals are now authored for the Lilly Control rotation scenario in `antithesis/workload/control/scenarios.py:246-257`. Audi, Porsche, Ziggy and Galileo effect routes and a hosted baseline remain uninstrumented/unrun. A request already admitted under the relevant domain lock before the rotation commits may finish; order by the domain transaction/lock, not by client send time.

## Evidence and failure history

- `marshall/lib/marshall_web/control_api.ex:22-37` authenticates before upgrade; `marshall/lib/marshall/control/socket.ex:21-34,118-142` retains principal and dispatches separate tasks. This creates the long-lived socket/credential-rotation race.
- `marshall/lib/marshall/control/services/lilly.ex:26-45,50-55` binds a host but forwards its token into `ProvisionerRequests.handle`; `marshall/lib/marshall/compute/provisioner_requests.ex:63-75` calls the domain exchange. `marshall/lib/marshall/compute/credentials.ex:22-25,74-121` archives credentials on rotation/revocation and revalidates under the host lock.
- Other service boundaries explicitly pass the original token per request: `services/audi.ex:5-9,79-83`, `porsche.ex:5-9,44-49`, `ziggy.ex:5-9,43-48`, `galileo.ex:5-7,30-38`. Their domain credential mechanisms differ; do not infer a shared Lilly lock.
- ADR-0142's accepted Control decision and these source contracts motivate the property. No closed incident or current failing reproduction was found. These statements are claims to test, not proof that every route already enforces them.

## Fault history, independent oracle and workload

Establish authenticated/bound connections for each service, issue one benign request, commit a credential rotation or revocation through the real operator/domain path, then send a mutation-capable request over the old connection and a comparable request over a fresh current credential. Run the boundary in both lock orders and with a response path cut. The oracle queries current credential generation/status and independent durable operation identities or external/native effect witnesses. A refusal body by itself is insufficient if a task committed and its response was lost. Give every attempted operation a unique domain key; reconcile uncertain calls after recovery. The positive new-credential request confirms the service is still available.

Parameter menu: all five services; rotate/revoke/expiry; pre-fence and post-fence dispatch; socket retained/reconnected; response lost before/after domain commit. Expiry requires controlled time or short issued lifetime and must not assume hosted clock-fault support. Put a SUT branch checkpoint after per-request credential lock acquisition and before domain mutation, with fixed metadata only; never record tokens or bodies. Hosted real service plus PostgreSQL is required. Native effects need their own witness. No mutant, suite or hosted result exists.

## Open Questions

- None in the inspected route families; a hosted cross-node rotation race remains unrun.

### Investigation Log (2026-10-13)

#### Per-request credential audit

- Examined: service adapters in `marshall/lib/marshall/control/services/`, Audi `ingress/control_requests.ex` and `services.ex`, Porsche `ssh/control_requests.ex`, `ssh/commands.ex` and `ssh/authority.ex`, Ziggy `inference/control_requests.ex`, `inference/requests.ex`, `agents/model_calls.ex`, `agents/executor_rpc.ex`, Galileo `galileo/authorizations.ex` and `credentials.ex`, Lilly `compute/provisioner_requests.ex` and `credentials.ex`. Found: each adapter forwards its upgrade token; effectful domain calls reauthenticate current credentials inside their own transaction and service/host/gateway lock, with distinct locks per domain. Not found: a route that mutates using only the cached socket principal, or a current hosted race run. Conclusion: the source audit resolves the route question; the property remains a cross-node behavior to test.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/scenarios.py:246`. Lilly credential rotation through a live old Control socket and durable session oracle; Audi/Porsche/Ziggy/Galileo mutation routes remain outside this authored scenario. It is in current staged control-core command/dependency set. This records source presence, not a passing hosted or native result.
