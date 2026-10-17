# Command reference

This reference uses the same v1 command grammar as the SSH service.

Every command accepts `--json`. Mutation commands accept `--request-id ID`.
Creation, start, stop, deletion, relocation and request controls also accept `--timeout SECONDS` (1–3600,
default 120) and `--no-wait`. Memory is in MiB and disk size is in GiB.
Image identifiers are immutable `sha256:` digests returned by `images`.
Use `--after UUID` with the returned cursor to fetch another list page.

`new` selects OSS when `--profile` is omitted, as does the browser creation form.
Use `new --profile customer` to choose Customer explicitly. Customer machines
permit only owner SSH and serial-terminal access. All outbound network
connections, workspace sharing, and web/port exposure are disabled.
SSH reply traffic is allowed only on admitted owner connections. Choose an
appropriate non-Customer profile when networking or collaboration is required.

{{COMMAND_REFERENCE}}

Permissions are checked at execution time. Access shown in a previous list is
not a guarantee that a later operation is allowed. Sharing roles are `viewer`,
`operator` and `manager`; ownership and current permissions determine which
operations you may perform. SSH key commands affect only your own keys.

```porsche
help share add
ls --json
share add example-machine colleague@example.invalid viewer
share show example-machine
share remove example-machine colleague@example.invalid
ssh-key list
```

VM disks have a maximum capacity of **500 GiB** (536,870,912,000 bytes).
Creation and resize requests above this limit are rejected, including Porsche
`new --disk` requests.

## Clone a machine

Owners and managers can queue an independent copy:

```porsche
clone example-machine --name example-copy --request-id copy-1 --no-wait
request show copy-1
```

Different request IDs create separate copies, processed in order for each source.
Repeating the same ID returns the same request. Each copy captures the source's
files, specifications and power state when its turn begins. A running source stops
for snapshot capture and restarts while copying continues. The new machine belongs
to you, is private, and has a fresh address; sharing is not copied. Guest files and
credentials stored inside the disk are copied. RAM is not copied.

Queued requests recheck your access before execution. Use `request cancel copy-1`
before the destination is published; successful cancellation waits for any required
cleanup. Use `request retry copy-1` to resume a failed request rather than create
another destination. Clone accepts `--timeout` and `--no-wait`; a client
timeout does not cancel accepted work.

Cloning is currently unavailable for the Inception multi-disk profile.

## Relocate a machine

Owners, managers and team admins can move a machine to another eligible physical
host. The destination and transfer strategy are always selected by Marshall and
cannot be supplied through Porsche:

```porsche
relocate example-machine --request-id move-1 --no-wait
request show move-1
```

The machine keeps its identity, name, sharing, private address, image and requested
shape. A running machine may have bounded downtime while final disk state and
execution authority move. `request cancel move-1` is available only before handoff
commits. If destination activation or readiness fails after commit,
`request retry move-1` retries that retained destination. Both controls create
their own durable request receipt; use a distinct `--request-id` for each control.

## Resize a machine

Owners and managers can change a machine's CPU and memory; disk may only grow,
up to 500 GiB:

```porsche
resize example-machine --cpu 2 --memory 4096 --request-id grow-1 --no-wait
request show grow-1
```

An omitted option keeps the current size; a request with no size option is
refused. A running machine stops, applies the sizes and restarts; a stopped
machine stays stopped and grows its filesystem on the next boot. The receipt
follows the request's phases. `request cancel grow-1` is accepted only while the
machine is still stopping: the original sizes and holds are kept, and a running
machine restarts unchanged. `request retry grow-1` resumes a request that needs
attention from its recorded phase.
