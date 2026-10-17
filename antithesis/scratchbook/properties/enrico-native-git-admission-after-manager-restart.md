# enrico-native-git-admission-after-manager-restart

P1; high source confidence; safety `Always`, message **"Enrico native Git ownership bounds physical concurrent refreshes"**. Missing SDK assertion per [scan](../existing-assertions.md). Manager restart must not admit more than eight live native Git utility ownership trees or two exclusive refreshes of one repository, including result-before-task-exit and surviving descendants. A new Manager's BEAM counter is insufficient physical proof.

## Evidence and fault history

`enrico/lib/enrico/manager.ex:59-125,171-246` guards replay, per-repo busy and eight BEAM tasks; `refresh_supervisor.ex:8-20` couples Manager/task lifetime. `enrico/native/git-owner/src/main.rs:70-190` acquires one of eight stable inherited slot flocks and a per-repository lock before launching Git, then reaps descendants. [Focus 02](../discovery/property-candidates-02/enrico-native-refresh-cap-survives-manager-restart.md) emphasizes native overlap after Manager replacement; [focus 05](../discovery/property-candidates-05/enrico-native-git-admission-after-manager-restart.md) adds ninth refusal and freed-slot successor. Local receipts end on restart/eviction, so replay after that boundary is a separate Marshall intent question.

## Oracle, environment, and instrumentation

Pause eight real Git utilities after native admission using a deterministic allowed-origin fixture, restart Manager, then request a ninth and a same-repo attempt. Independently inventory /proc ancestry, original lock inodes/flock holders and Git effect accept times. After one real descendant retires, an eligible successor can enter during a healthy measured tail; uncertain cleanup may conservatively refuse. Vary 7/8/9/16 repos, same/different repo, caller/helper death, result-before-exit and inherited grandchildren. Hosted Linux with real Git/flock may establish this; fake task counts cannot. A `Reachable` marker records ninth admission refusal.

## Open questions

- Can the chosen hosted Linux image expose inherited lock holders across helper death with the same procfs and subreaper behavior as the native property suite? This needs an executed hosted probe; source alone establishes the mechanism, not its deployed observation.

### Investigation Log

#### How can real Git pause after slot acquisition without changing production ownership or executable path?

- Examined: `enrico/native/git-owner/src/main.rs:100-190`, `enrico/lib/enrico/git.ex:52-95,392-443`, and `nix/verification/tests/machines/enrico-service/driver.py:300-325`.
- Found: the owner acquires a stable slot flock and per-repository lock before spawning the real Git executable. The packaged service fixture uses `systemctl kill --signal=SIGSTOP --kill-whom=all nginx.service` to pause a verified-TLS Git fetch while retaining the production executable and owner path.
- Conclusion: resolved. Start the eight fetches against distinct small fixture repos, pause the fixture HTTPS server before the Git network response, then verify lock holders and refusal. Confirm each helper acquired its lock before declaring saturation.

#### Does hosted Linux preserve inherited-FD and descendant custody with observable locks?

- Examined: `enrico/native/git-owner/src/main.rs:73-190`, `enrico/native/git-owner/tests/histories.rs:399-403,770-800`, and `enrico/native/git-owner/CONTRACTS`.
- Found: slot/repository flock descriptors are inherited by Git descendants, `PR_SET_CHILD_SUBREAPER` and parent-death fencing are installed, and native tests inspect descendant/lock custody including an escaped session. Linux procfs and flock holder observation are available in the existing Nix VM scope.
- Not found: an executed Antithesis hosted container observation proving its PID namespace and permissions expose the same descendants.
- Conclusion: partial. Use `/proc/<pid>/fd` inode and `/proc/locks` plus a real ninth Git attempt in the hosted image; keep generated native test evidence separate until that run executes.

#### Can a local deterministic fixture satisfy Enrico's fixed source-origin policy without weakening it?

- Examined: `enrico/lib/enrico/git.ex:48-70,410-411`, `nix/verification/tests/machines/enrico-service/default.nix:12-40`, and `driver.py:17-21`.
- Found: production code always forms `https://github.com/<owner>/<repo>.git`; the Nix machine maps `github.com` to loopback and serves a local bare Git repo over TLS with a trusted fixture certificate. No arbitrary URL or runtime source override is used.
- Conclusion: resolved. Reuse DNS and CA fixture design in the hosted topology, with only synthetic repository labels.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `repository`. real-hosted-git-and-native-helper; independent witness: fixed-origin Git request log, bare mirror SHA/blob and original flock inode. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/repository/scenarios.py:439`. Native Git slot-inode and passive /proc lock snapshot across an exact Enrico service restart; no hosted campaign or general descendant-custody acceptance. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.

**Hosted finding (2026-10-17, run d2dd2d24d786946c775aa57068d44393-65-0):** two counterexamples were an oracle race, not an Enrico defect. A partition failed one of the eight held refreshes (`refresh_failed git_failed`), freeing its slot; the ninth was then correctly admitted (`refresh_started`) and its own git-owner took that slot, so the later witness again showed eight held. The oracle now brackets the ninth status read with holder-identity snapshots: the same eight `(slot, holder_pids)` pairs must hold before and after the read and the ninth must hold no repository lock, otherwise the case is logged unexercised. Run 0c1fe312 (round 3) showed the first bracket version never witnessed the pre-admission eight because it read the periodically published snapshot once; the pre-admission witness now polls for up to five seconds like the post-admission one, and the ownership-bound Always is evaluated even when the ninth case is unexercised.
