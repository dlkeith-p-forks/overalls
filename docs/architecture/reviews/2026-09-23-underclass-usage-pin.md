# Underclass usage and monitor pin

## Scope and architecture impact

Advance the immutable Underclass source from `aaca487` to `8cc7321`. Three
upstream commits add per-attempt token accounting, admin usage queries, and a
read-only terminal monitor. ADR-0081's independent host-local pool, loopback
listener, runtime secret custody, and tailnet publication remain unchanged.
The new ledger extends each pool's SQLite state and recovery scope.

## Findings

The upstream ledger records model, account ID and label, full prompt cache key
when supplied, status, and optional input/output counts for every upstream
attempt. Missing usage stays unknown. Rows are retained indefinitely, including
after account deletion; disk use therefore grows with traffic. The new usage
and monitor routes sit behind the existing admin-token middleware. The monitor
reads live state and database aggregates without writing or calling providers.
Its recent-request entries omit prompt cache keys and raw account IDs.

Copilot streaming may add a usage request option and retry once if the upstream
rejects it before streaming. This affects upstream request behavior but leaves
the client-facing proxy endpoint and the independent-pool boundary intact.
The added diagnostics use request IDs, status, numeric counts, and errors; the
review found no new credential or prompt-body logging.

## Verification

The immutable source and Cargo dependency hashes were resolved from the
upstream revision. Local package and Nix checks, upstream locked Rust tests,
the ADR checker, and code-contract syntax check were run for this pin. These
local checks do not establish live provider usage accuracy, tailnet ACL
behavior, or acceptable long-term SQLite growth.

## Remaining gaps

Measure ledger growth and choose retention before promising durable usage
history. ADR-0081's live provider, tailnet, and encrypted restore acceptance
remain open.
