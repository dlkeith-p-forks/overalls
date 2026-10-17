# Agent threads

Use global **Threads** for tasks with automatically created machines. The
machine navigation no longer includes an Agents tab. The direct
`/machines/:id/threads` page still shows its root thread and permits creating a
child thread or sending a prompt under existing machine authority.
A prompt from a user with write access starts a
stopped machine. If the machine has been deleted or can no longer run, the
thread shows an unavailable result.

The `overalls` CLI can send one prompt and print its final response:

```sh
overalls agent --machine <machine-uuid>
```

Type a prompt and press Enter. For a multiline prompt, pipe UTF-8 text into
the command. The CLI prints an approval URL and a short request code. Open the
URL in a browser, sign in, check that the machine and request code match, and
approve. The CLI then submits the prompt and waits for the final answer.

To use an existing child thread, add `--thread <thread-uuid>`. The CLI requires
the same write access as the browser prompt form. Approval lasts one hour and
is scoped to that machine; each new CLI invocation requests a fresh approval.
The CLI keeps its secret in memory and sends it only to Marshall over HTTPS.

The guest image runs `overalls agent-executor` as a service. It receives only
fenced tool commands through the private VM service. Marshall owns thread
history, model calls, child-agent joins and recovery.

Verification covers the Marshall prompt/API flow, Ziggy model polling, the
packaged CLI against a synthetic HTTPS control, and a full fleet run in which
a shared operator wakes a stopped guest and completes a model and guest tool
round trip. Browser-approved CLI use through that same live model path remains
untested; see the
[architecture review](../architecture/reviews/2026-09-23-agent-threads-foundation.md).
