---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# brady-listener-socket-worker-bound

**Claim, priority, confidence.** P1 safety with progress, high confidence in intended listener contract. Each transparent HTTP/HTTPS listener accepts no more configured live connection workers; overload closes the excess socket, and a freed worker slot permits a later legitimate connection during a healthy quiet interval. Proposed unique assertion: Always("brady listener overload never creates an extra live worker or leaked accepted FD", live_worker_sockets <= configured_listener_max). Supplementary Sometimes("brady listener recovers a freed worker slot after saturation", successor_valid_request_observed_at_origin) is meaningful progress. Both are missing per ../../existing-assertions.md.

**Source and history.** brady/lib/brady/listener.ex:24-47 binds transparent sockets and defaults maximum to 256 per scheme. handle_call :worker at :53-71 creates a monitored worker only below maximum and returns busy at saturation; :76-89 retires DOWN and closes listeners/workers on termination. accept_loop at :92-115 transfers accepted socket ownership or closes it on refusal/transfer failure. brady/lib/brady/application.ex starts separate scheme listeners. The source contract at :17-20 explicitly requires a bounded worker count; no current hosted FD-leak proof is present.

**Workload and oracle.** Via a real transparent interception route, hold N accepted connections without completing headers, race N+1 attempts, and inspect /proc/PID/fd socket inode count plus actual monitored worker PIDs and origin fixture receives. Saturated excess sockets should close promptly, while held N remain live. Close or kill one worker, then send a valid local-origin request through the same listener and observe actual bytes at the origin and client. Separately keep the other scheme healthy to check listener isolation. Kernel accept backlog sockets are distinguished from handed-off worker sockets.

**Limit menu.** Test-only configured 1, 2, 255, 256 max_connections; exact N and N+1, simultaneous worker death and transfer failure, short/long held connections. Default 256 should be exercised at least once in a native/TCG campaign if resources allow.

**SUT guidance and limits.** Mark accept, worker admission/busy and owner transfer; count socket inodes externally. Transparent IP requires native Linux privilege/network setup; ordinary HTTP mocking cannot validate kernel socket closure. Open questions: Which TCG router fixture can produce transparent connections and inspect socket inodes without interfering with the accepted backlog? What measured quiet interval is appropriate for freed-slot progress?

**Architecture/HLDD impact.** No design or handbook change; tests existing Brady listener capacity.
