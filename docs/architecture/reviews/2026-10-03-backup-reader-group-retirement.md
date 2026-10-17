# Backup reader group retirement

## Scope and architecture

Baseline `feafe9439c1ebbb7333123cbe764427f79d1f6f3`. ADR-0070 retains its accepted
rationale and historical acceptance status. This production repair enforces the
existing requirement that backup readers stop before control reaches snapshot
cleanup. Protocols, backup authority, deployed service roles and configuration
remain unchanged. Python helper execution now relies on Linux waitid WNOWAIT and
visible proc task inventory, consistent with the NixOS host runtime.

## Findings and repair

A direct process could exit while its same-group descendants retained stdout and
source descriptors. The original finally called killpg only if the direct child
was still live, so timeout, successful EOF or failed EOF could return with readers
still alive. An isolated actual-process reproduction confirmed the leak; introduced
processes were explicitly retired. The first property failed three fixed cases
in 7.252 seconds, `/tmp/kittens-reader-baseline.log`.

An initial unconditional kill exposed two review findings: EOF already reaped the
leader before numeric group signaling, and asynchronous SIGKILL did not establish
reader death before return. The repair observes direct-child exit with WNOWAIT,
retaining its PID/group identity; repeatedly signals that group, checks every
visible task for non-zombie same-group members, then reaps the direct child.
Retirement requires two consecutive empty inventories with another group signal
between them, reducing the in-flight fork/enumeration race. This relies on Linux
proc visibility of existing tasks; it is not external containment proof.
Unavailable inventory withholds return and snapshot cleanup. A zombie leader can
still have live worker threads; both inventory and a native pthread regression
cover that case. Fixture cleanup uses pidfds with group/starttime matching.

## Properties and review

`test_exited_leader_reader_group_is_retired` varies timeout, success, nonzero exit
and output overflow with one/two/three actual same-group descendants opening the
source file before their leader exits. Four fixed plus four generated histories
assert death immediately after return, and preserve source bytes.
`test_zombie_leader_does_not_hide_live_reader_threads` has two fixed plus three
generated one/two/three-worker histories. Independent native proc witnesses show
leader Z and worker threads live before invoking actual group inventory.
The helper is compiled as C11 with pthreads, Wall/Wextra/Werror. Inputs and native
C/Python interfaces are typed. Final composed pinned checks passed.

Reviewed root/Nix/test/backup contracts, run callers and subprocess finally paths.
Fresh review caught and drove repair of PID reuse, delayed death oracle, unsafe
fixture cleanup and zombie-leader inventory. Thread fixture passed in 0.610 seconds;
an isolated leader-only inventory mutant failed the same property in 0.140 seconds.
The actual group-return property passed in 3.723 seconds before the pthread fixture
addition. No mutant changes entered tracked production source.
After the two-empty-inventory hardening, all four CommandTest tests passed in
5.590 seconds with the pinned Python 3.13 environment and native pthread helper;
local transcript `/tmp/kittens-reader-two-scan-focused.log`. This focused run
does not replace the composed Nix gate or packaged cleanup acceptance.

## Contract limitation

The original direct process.wait after SIGKILL already lacked a hard native
retirement bound. Descendant retirement preserves that safety-first wait: an
uninterruptible kernel I/O task or persistently unavailable proc inventory can
stall retirement. This is an explicit existing mismatch with the strict elapsed-
time wording in backup-command-bounded-readers; that normative contract is not
weakened, and passing ordinary-process properties do not prove its kernel-fault
bound. Command deadline bounds execution; it is not death proof. Returning an
ordinary BackupError with unconfirmed readers would allow snapshot cleanup and
violate the stronger safety requirement. A genuinely bounded coordinator return
requires durable deferred cleanup and stable external containment ownership;
that architectural extension remains open, rather than silently authorizing it.

## Execution and gaps

Before pthread fixture addition, pinned Python 3.13 backup-types passed in 16 seconds,
exit 0; archive `1791019706124-866640-0.jsonl`. Earlier import-order failure is retained
at `1791019419581-691055-0.jsonl`. Final pinned backup-types check passed in
8 seconds, exit 0; archive `1791021243122-1840588-0.jsonl`. It includes native
C11 pthread compilation, Ruff format/lint, ty and all composed runtime tests.
Packaged native cleanup check passed in 121 seconds, exit 0; archive
`1791021266949-1854238-0.jsonl`. It exercises installed systemd cleanup/recovery
with the repaired subprocess implementation, not mounted-reader or kernel-fault
acceptance. After merging main, a focused pinned real-Restic check passed in
111 seconds, exit 0; archive `1791021593395-2061362-0.jsonl`. Both runtime
cancellation/session-drain and fixed publication-window tests passed against
the repaired modules. The uploaded-point full-suite record remains historical
evidence for its original revision; this focused check establishes only the
two tested repair paths.
Escaped sessions/groups, inaccessible proc native recovery, uninterruptible I/O,
cgroup/daemon loss, physical power loss and hosted faults remain separate gaps.
