# enrico-interruption-preserves-published-head

P1; medium-high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
`Always(last Marshall-published successful commit remains resolvable/readable
after failed/interrupted refresh and service restart)`; message
**"Enrico interrupted refresh keeps the last published commit browsable"**.
The invariant is immutable published commit custody, not that every mutable
branch ref can never advance before the final refresh response.

Evidence: `enrico/lib/enrico/git.ex:47-94` (`refresh`) uses atomic fetch and
new-clone staging/rename; `:106-115` (`retain_head`) retains prior/new default
commit in refs/enrico/retained. A crash after atomic fetch but before HEAD update
may expose changed refs; the older published commit must still be addressable.
`manager.ex:58-63` explicitly ends local attempt replay retention on restart or
1024-receipt eviction; `:171-222` generation matching excludes stale task completion.
Enrico CONTRACTS require browsable last publication and native writer ownership.

History: real Git fixture serves commit A; complete/publicly publish A. Force push
to B, switch default branch, then interrupt ls-remote/fetch/HEAD update/retained
ref publication or reply. Kill BEAM/native owner separately; restart, retry retained
Marshall intent and browse A by immutable SHA. New clone interrupted before
rename must not be advertised as a successful mirror. Retain real native locks.

Independent oracle: fixture-known Git commit/tree/blob bytes for A and B, actual
local Git resolution/content and committed Marshall publication receipt. Volatile
Manager `missing` after restart is allowed and does not imply mirror loss. Do not
demand no second fetch after service restart because its explicit receipt namespace
ended. Success receipt must match a resolvable actual commit, not a status atom.

Guidance: `Reachable` **"Enrico browsed its last published commit after interrupted force-push refresh"**;
**"Enrico rejected a stale refresh-generation completion after recovery"**.
Replay anchors before/after atomic fetch, symbolic HEAD, retained ref and staging
rename, plus native caller EOF. Keep URLs/Git output out of diagnostics.

Values: active refreshes 1/7/8 and ninth refused; retained receipt count
1023/1024/1025; SHA1 and valid Git fixtures, A/B default branches, failed/partial
network transfer, valid prior mirror versus initial clone. Hosted real Enrico/native
Git helpers/fixture cover publication and ownership, but fixed github.com origin
must be honored through reviewed local transport arrangement rather than enabling
arbitrary production origins. Native inherited slots/descendants need real kernel.

Open questions: What harness-only network arrangement can provide deterministic
Git source effects while preserving the production fixed-origin boundary?

### Investigation Log

#### Does failed refresh preserve every old branch ref?

Examined Git.refresh/3 atomic fetch, symbolic HEAD update and retain_head/2.
Found retained immutable prior HEAD but no transactional grouping across fetch
and HEAD update. Resolved property to last published immutable commit custody;
do not infer that a reported failure rolls back every Git ref mutation.
