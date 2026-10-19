# Push notifications

Mila, the Overalls mobile app, can tell you when an agent needs your input:
when a planning turn asks you a question or proposes a plan. A notification
only says that something needs attention; opening it takes you to the thread
in Mila, which then fetches the details over your own SSH connection.

Notifications go to the devices of every person who can currently act on the
thread, except the person whose action caused it. People with view-only
access are not notified.

## Devices

Mila registers your phone when you allow notifications. The registration is
bound to the SSH key Mila uses, so removing that key from your account also
revokes the device. Each account can have up to ten active devices.

You can review and manage devices with Porsche:

```porsche
device ls
device prefs 7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12 --enabled false
device rm 7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12
```

`device prefs` pauses or resumes notifications for one device. `device rm`
revokes it permanently; Mila registers again the next time you allow
notifications. Deleting or retiring your account revokes all its devices.

## Privacy

Apple and Google deliver notifications only to apps signed by the app's
publisher, so every Overalls deployment sends notifications through one shared
relay, Susan, at `https://notifications.overalls.dev`. Your deployment cannot
be configured to use another relay.

Susan sees the IP address of your deployment and when each notification is
sent, an opaque push key issued to your device, an encrypted message and the
notification kind. The message is encrypted on your deployment to a key that
only your device holds, so Susan cannot read where the notification leads.

Susan never sees your prompts, agent output, thread or machine names, email
address, SSH keys or any other account data.

Susan keeps an append-only audit log of key issues, accepted and refused
notifications, rate limits and delivery outcomes. Each entry records only the
action, reason, a fingerprint of the sending deployment, the push key ID, the
provider (Apple or Google), the outcome and a delivery ID. It does not record IP
addresses, push tokens, keys or encrypted messages. Audit entries are deleted
after 90 days.

Your deployment keeps delivery records for seven days and stores only a digest
of each push key in its audit history.

## Turning notifications off

- An operator can disable notifications for the whole deployment with
  `services.marshall.notifications.enable = false`. Registration is then
  refused and nothing is sent to Susan.
- You can pause a single device with `device prefs DEVICE_ID --enabled false`.
- You can revoke a device with `device rm DEVICE_ID`.

Notifications are a convenience. While Mila is open, it follows your threads
through its own live watch stream, which works even when notifications are
disabled or Susan is unavailable.
