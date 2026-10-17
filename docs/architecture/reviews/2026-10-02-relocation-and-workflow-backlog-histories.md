# Competing relocation and workflow backlog histories

## Scope and architecture impact

Test-only evidence under ADR-0037's retained relocation requirements, ADR-0050's
capacity authority and ADR-0133's measurement boundary. No production domain,
protocol, persistence schema, execution fence or cleanup authority changes.

## Competing relocation property

`marshall/test/marshall/compute/relocation_competing_history_test.exs` creates two
stable stopped workloads on one source before enrolling a distinct destination.
Actual `Compute.relocate` admits the incumbent and occupies both endpoint slots.
One/two/four attempts to relocate the independent workload with the same request
identity refuse `transfer_busy` without changing complete allocation and relocation
records. This uses fresh per-draw SQL sandbox ownership, without an additional
application transaction around expected refusal.

After cancellation, authenticated exchanges offer commands whose parsed
relocation/placement/epoch exactly match the intended receipts. Generated wrong
placement or epoch receipts refuse without inventory changes. Either endpoint
may confirm first; coordinator advancement and repeated competitor admission
still retain occupancy. Both receipts permit coordinator release, retaining the
exact original two slot IDs and first-release timestamps. Source restoration and
destination disk cleanup remain pending. Fresh ordinary reports permit actual
competitor admission. Duplicate incumbent receipts/advances and competitor request
replay preserve its complete allocations and the original release history.

Fresh review found a vacuous all-elements assertion when released history was
empty. The repaired oracle requires the initial exact slot-ID set before checking
timestamps. This is database authority with synthetic physical outcomes, not
proof that native streams have ceased.

## Workflow backlog extension

`service_level_backlog_history_test.exs` retains its operation family and adds
102 real accepted, measured SSH receipts bound to a queued clone through the
production `ServiceLevelAdmission` action. Each family has fixed zero/below/at/
above/all-overdue witnesses around the 100-attempt limit, plus generated overdue
counts and future-first ordering. Sandbox-only SQL clock controls select which
measurements are overdue; they do not change the SSH receipts.

The independent oracle checks exact first/second scan counts, terminal row
immutability across later scans, numeric totals/buckets/durations and source
lifetimes. Remaining overdue rows preserve all seven publication files exactly;
successful publication advances one shared sample clock. Complete VM, operation,
reservation, placement, address, transfer-slot, clone and SSH receipt inventories
remain unchanged. Fresh review found that filtering inventory to only the original
VM could miss unexpected destination allocations; comparisons now include all
fixture rows under sandbox isolation.

## Verification state

The combined focused run passed two properties, seed `281508`, in 49.7 seconds.
The complete pinned command exited0 with warnings-as-errors; log:
`/tmp/overalls-relocation-workflow-focused.log`. Full batch precommit exited0: 1,418 checks (217 properties, 1,201 tests), two exclusions, seed981745,1055.5seconds; forced Dialyzer36.71seconds with zero errors, skips or unnecessary skips.
Log: `/tmp/overalls-relocation-workflow-full-gates.log`.
This full collection precedes the final exact-bucket assertion strengthening;
the focused follow-up passed two properties, seed `437252`, in 48.7 seconds
with warnings-as-errors and terminal exit0. Log:
`/tmp/overalls-relocation-workflow-exact-buckets-focused.log`. Fresh review verified
the complete eight-bucket vector independently from fixture duration/count. The earlier operation-only result retains its original
revision and scope; it does not establish workflow backlog coverage. The running
integrated Marshall gate started before these extensions and is a separate result:
1,417 checks (216 properties, 1,201 tests), two exclusions, seed505231,
1006.0seconds; forced Dialyzer43.99seconds with zero errors and terminal exit0.
Log: `/tmp/overalls-namespace-clone-integrated-full-gates.log`.
That earlier collection excludes both extensions; their separate focused result
above covers the reviewed current oracles.

ADR structure, generated scenario coverage, reviewed handbook receipts, source
views and generated options checks passed. Evaluated HLDD initially failed because
the Git-derived Nix source omitted untracked test/review files; staging those exact
files repaired the source inventory. The staged evaluated check passed9seconds,
capture `1790980238478-2173224-0.jsonl`. This is documentation verification, not
execution evidence for either property.

## Remaining gaps

Independent publishers, competing committed admission, process restart, physical
stream cessation and restoration, collector/exporter behavior, uncertain network
delivery and hosted fault histories remain outside these rollback sandbox tests.
