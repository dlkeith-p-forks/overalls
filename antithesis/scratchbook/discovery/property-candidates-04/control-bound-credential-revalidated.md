# control-bound-credential-revalidated

Priority: P0. Confidence: high in the intended contract; no hosted run. Type: Safety, with a recovery reach anchor.

## Guarantee and proposed assertions

After a service credential is rotated, revoked or expires, an already welcomed socket cannot use its cached upgrade principal to authorize a new domain effect. Use `Always(no_effect_after_credential_fence, "Bound control sockets revalidate current credentials before each domain effect")` on every pre/post-fence exchange. `Reachable("Bound control credential rotation is refused on the next request")` marks a witnessed refusal after the committed rotation. Both are missing in the fresh `../../existing-assertions.md` scan. A request already admitted under the relevant domain lock before the rotation commits may finish; order by the domain transaction/lock, not by client send time.

## Evidence and failure history

- `marshall/lib/marshall_web/control_api.ex:22-37` authenticates before upgrade; `marshall/lib/marshall/control/socket.ex:21-34,118-142` retains principal and dispatches separate tasks. This creates the long-lived socket/credential-rotation race.
- `marshall/lib/marshall/control/services/lilly.ex:26-45,50-55` binds a host but forwards its token into `ProvisionerRequests.handle`; `marshall/lib/marshall/compute/provisioner_requests.ex:63-75` calls the domain exchange. `marshall/lib/marshall/compute/credentials.ex:22-25,74-121` archives credentials on rotation/revocation and revalidates under the host lock.
- Other service boundaries explicitly pass the original token per request: `services/audi.ex:5-9,79-83`, `porsche.ex:5-9,44-49`, `ziggy.ex:5-9,43-48`, `galileo.ex:5-7,30-38`. Their domain credential mechanisms differ; do not infer a shared Lilly lock.
- ADR-0142's accepted Control decision and these source contracts motivate the property. No closed incident or current failing reproduction was found. These statements are claims to test, not proof that every route already enforces them.

## Fault history, independent oracle and workload

Establish authenticated/bound connections for each service, issue one benign request, commit a credential rotation or revocation through the real operator/domain path, then send a mutation-capable request over the old connection and a comparable request over a fresh current credential. Run the boundary in both lock orders and with a response path cut. The oracle queries current credential generation/status and independent durable operation identities or external/native effect witnesses. A refusal body by itself is insufficient if a task committed and its response was lost. Give every attempted operation a unique domain key; reconcile uncertain calls after recovery. The positive new-credential request confirms the service is still available.

Parameter menu: all five services; rotate/revoke/expiry; pre-fence and post-fence dispatch; socket retained/reconnected; response lost before/after domain commit. Expiry requires controlled time or short issued lifetime and must not assume hosted clock-fault support. Put a SUT branch checkpoint after per-request credential lock acquisition and before domain mutation, with fixed metadata only; never record tokens or bodies. Hosted real service plus PostgreSQL is required. Native effects need their own witness. No mutant, suite or hosted result exists.

## Open Questions

- Does each mutation-capable Audi, Porsche, Ziggy and Galileo route authenticate the credential under the appropriate current-domain lock before an effect? The service forwarding path is confirmed; route-by-route audit remains.
