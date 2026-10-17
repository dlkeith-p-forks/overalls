# Automation

Use SSH exec commands and durable request IDs to automate machine management.

## Results and completion

Use `--json` for machine-readable results. An exec invocation writes one result
to standard output; progress goes to standard error. Check the SSH command's exit
status as well as its result. A failed command exits nonzero.

Creation, start, stop, deletion, relocation and request controls wait up to 120
seconds for the matching physical result. A request being accepted or acknowledged is not proof that the machine
has reached the requested state. `--no-wait` returns the accepted request without
waiting; `--timeout SECONDS` changes the wait limit. Timing out or disconnecting
does not cancel accepted work.

## Retry safely

Choose a stable, unique request ID for each intended mutation. Reuse it when
retrying that same mutation after losing a reply. Request IDs contain 1–128 ASCII
letters, digits, underscores, dots, colons or hyphens, and start with a letter or
digit. Do not reuse one ID for different operations.

```porsche
new --name example-machine --request-id example-create-001 --no-wait --json
request show example-create-001 --json
new --name example-machine --request-id example-create-001 --no-wait --json
```

The accepted request retains its normalized command and resolved resources.
Retrying cannot retarget a different machine after name reuse or silently select
a different default image. Query the original request after a lost response or
timeout. Request status remains subject to current account authorization, including
after the machine is archived.

Key removal prevents subsequent commands and status polls from that session.
Accepted jobs continue. Reconnect using another registered key, or use email login
to manage your keys in Marshall. Do not put private keys or approval links in logs.
