# Terminald explicit kill under withheld viewer credit

## Scope and architecture impact

Reviewed ADR-0082, root/native contracts and actual session, PTY and viewer code.
Explicit kill remains guest terminal authority; natural shell EOF retains raw
queued-output draining. No wire format, identity, deployment placement or durable
store change. This repair completes local cancellation within existing session
lifetime and bounded-resource decisions; ADR-0082 stays accepted and partial.

## Findings and repairs

An actual PTY and connected Unix viewer with a small kernel send buffer drove
its queue above the high watermark. Explicit kill marked the shell dead but the
pump remained waiting for credit. The original regression failed in 2.08 seconds:
`/tmp/kittens-terminald-credit-kill-reproduction.log`. Session registration and
ring quota remained held while the peer stayed connected.

The first repair released pressure but did not prove viewer retirement. Fresh
review required an independent permit-count oracle before peer departure. That
strengthened history exposed the blocked socket write: queue flags alone cannot
interrupt a kernel write before its send timeout. Its failing shrinking run was
intentionally stopped after repeated observations to repair the concrete flaw;
it is not passing evidence. Explicit kill now aborts queues and shuts down each
registered socket while holding the session lifetime lock. Owning close paths
remove registration under that lock before descriptor close, preventing stale
shutdown against a reused descriptor.

Fresh review also found that a top-of-loop alive check cannot wake an already
blocked PTY read when another process holds a quiet slave. The sole reader now
polls readiness with a bounded 100 ms wait before reading, preserving shared
input descriptor flags. Explicit cancellation is observed independently of slave
EOF. The owned process group and direct leader receive SIGKILL before releasing
the lifetime lock; retirement cannot reap/release the leader PID first. Natural
EOF closes queues without aborting the retained suffix.

## Verification and limits

Generated watermarks include 1, 1023/1024/1025, 32767/32768/32769 and the
configured 1 MiB boundary family. Histories use actual PTYs, kernel socket
pressure, exact session/ring retirement and viewer permit release while the peer
remains connected. An optional HUP-ignoring descendant shares the owned group;
the fixture disables job control and independently checks group membership.
Fixed configured-watermark histories exercise both descendant cases. A separate
native test keeps an independent quiet slave descriptor open through retirement.

Three focused checks passed in 6.73 seconds before the fixture's thread-safe
ptsname lookup and group-membership assertion were added. Log:
`/tmp/kittens-terminald-credit-kill-poll-final.log`. The final full native suite passed all 46 checks in 20.59 seconds,
including the existing natural EOF suffix drain, and Clippy passed with warnings
denied in 1.95 seconds. Logs: `/tmp/kittens-terminald-credit-poll-full-native.log`
and `/tmp/kittens-terminald-credit-poll-clippy.log`. The source-built Nix
terminald gate passed in 71 seconds, archive `1791002357505-4100019-0.jsonl`,
including all tests and warnings-denied Clippy in the pinned derivation.
Fresh independent review found no remaining concrete blocker in this scope.
All-file prek passed logging, Ruff format/check, ty and reviewed handbook gates.
ADR/options/coverage/views checks passed; evaluated Nix HLDD passed in 24 seconds,
archive `1791002851285-47120-0.jsonl`. Logs:
`/tmp/kittens-terminald-credit-final-static-hldd.log`. These gates preceded this
execution-record append; final receipts are reviewed and checked at commit.
Integration into main and its final combined checks remain pending.

This establishes local Linux PTY/socket cancellation, not authenticated vsock,
Firecracker/browser composition, aggregate 64 MiB admission, escaped process-group
cleanup or physical-host isolation. Closing the PTY master and releasing quota
does not establish that every escaped descendant has died. Hosted Antithesis
workload reach and mutation validation remain separate.
