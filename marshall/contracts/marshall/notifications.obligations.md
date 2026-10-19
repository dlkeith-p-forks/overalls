---
modules: [Marshall.Notifications, Marshall.Notifications.Delivery, Marshall.Notifications.DeliveryWorker, Marshall.Notifications.Device, Marshall.Notifications.DeviceActions, Marshall.Notifications.InstallIdentities, Marshall.Notifications.InstallIdentity, Marshall.Notifications.Producer, Marshall.Notifications.Reconciler, Marshall.Notifications.Retention, Marshall.Notifications.Retry, Marshall.Notifications.Susan]
---

# Notifications obligations

## Purpose

These contracts cover the Marshall side of Mila push notifications (ADR-0225)
as observed in the BEAM test VM against PostgreSQL with an in-process Susan
stub. They do not establish real APNs/FCM delivery, Susan's own limits or
audit log (ADR-0224), TLS to the production origin, or device-side
decryption; the `push-notifications` NixOS machine test and the Mila and
Susan workstreams carry that separate evidence.

### marshall.notifications.I1 — Susan origin is a compiled constant
- **scope:** `Marshall.Notifications.Susan.origin/0`
- **must:** The production origin MUST be `https://notifications.overalls.dev`; the configurable override MUST be read only inside the `MIX_ENV=test` compile branch, so no runtime configuration of a production build can redirect pokes.
- **kind:** security
- **status:** active

### marshall.notifications.I2 — Pokes are content-free and end-to-end encrypted
- **scope:** `Marshall.Notifications.DeliveryWorker.perform/1`
- **must:** Every request to Susan MUST be the canonical eight-member signed body whose only content is a v1 poke that opens solely with the device's X25519 private key for this deployment; the body MUST NOT contain the route, thread or machine identifiers.
- **kind:** security
- **status:** active

### marshall.notifications.I3 — Retries never double-notify and gone devices are invalidated
- **scope:** `Marshall.Notifications.DeliveryWorker.perform/1`, `Marshall.Notifications.Retry.decide/2`
- **must:** Two 503 responses followed by 200 MUST yield exactly one successful send under one delivery id and a delivered row; a 410 MUST invalidate the device and drop the delivery so later pokes are never sent.
- **kind:** functional
- **status:** active

### marshall.notifications.I4 — The operator switch disables push end to end
- **scope:** `Marshall.Notifications.enabled?/0`, `Marshall.Notifications.register_device/2`, `Marshall.Notifications.Producer.produce/2`
- **must:** With notifications disabled, registration MUST be refused with push_disabled and committed agent questions MUST produce no delivery.
- **kind:** security
- **status:** active

### marshall.notifications.I5 — Revocation follows the SSH key and the account
- **scope:** `Marshall.Notifications.revoke_for_key!/2`, `Marshall.Notifications.revoke_for_user!/2`
- **must:** Removing the SSH key that registered a device, or retiring its account, MUST revoke the device in that transaction; a revoked device MUST NOT receive a poke.
- **kind:** security
- **status:** active

### marshall.notifications.I6 — Audit and receipts hold digests only
- **scope:** `Marshall.Notifications.Device`, `Marshall.SSH.Commands`
- **must:** Device versions and the pinned `device register` receipt MUST NOT contain the push key or its ciphertext; only its digest may be retained.
- **kind:** security
- **status:** active
