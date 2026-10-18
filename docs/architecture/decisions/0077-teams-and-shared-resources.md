# ADR-0077: Teams and shared resources

- ID: ADR-0077
- Date: 2026-09-19
- Status: accepted
- Implementation: partial
- Components: Marshall, Porsche, NixOS
- Supersedes: none
- Superseded by: none

## Context

The user authorized an sample-host-style team concept: multiple accounts share a
pool of machines, team admins manage member machines, and team-owned
resources such as integrations and their secrets are shared or tagged within
the team. Roles are owner, admin and member. Billing, SSO and quotas are out
of scope. No backwards compatibility is required.

## Decision

Add `Marshall.Teams` with `Team`, `TeamMember` and `Transfer` resources. A
team has exactly one owner-role member, enforced by a database constraint;
admins and members are additional roles on the same membership table, one
current membership per `(team, user)`. Machines gain an optional immutable
`team_id` assigned at provisioning. Team authority is expressed through the
existing Cedar policy engine by extending the VM entity with team membership
sets and adding Integration and Team entities with actions; membership is
re-read from PostgreSQL for every decision and denial remains fail-closed.
Admins may manage team machines; members may read and use them; owners hold
every team action. Integrations are owned by a user XOR a team; team-owned
integrations are automatically available to machines owned by team members
in addition to explicit attachments.

Ownership transfer is a consent workflow modeled with AshStateMachine on the
`Transfer` resource (`pending`, `accepted`, `declined`, `cancelled`); only
the current owner may offer, only the target member may accept or decline,
and acceptance swaps the owner role and demotes the previous owner to admin
inside one transaction. Membership and transfer mutations emit admin events.
Porsche gains `team` commands and the web console gains team management.

## Alternatives

Cedar entity ancestry (`memberOf`) was rejected: the codebase expresses
memberships as flat `Set<User>` attributes rebuilt per decision, and
introducing parents would be a new pattern without a need. Extending
per-machine `Access.Grant` sharing instead of teams was rejected: grants are
per-machine and cannot express resource ownership or pooled machine
families. A dedicated invite/email flow was deferred: membership is added by
team admins in v1.

## Consequences

Team membership grants machine access beyond per-machine grants; the Cedar
matrix and its property tests must express both. Deleting a user requires
team membership cleanup alongside existing retirement flows. The
exactly-one-owner invariant must hold across transfer states, crashes and
concurrent offers, which is enforced by database constraints and the state
machine's closed transitions.

## Invariants and verification

Cedar matrix property tests cover role/action combinations for machines and
integrations including fail-closed denial for non-members. Transfer tests
cover the full transition matrix (invalid transitions rejected, terminal
states immutable, exactly-one-owner maintained, only owner may offer, only
target may accept). Database tests cover partial unique indexes and deferred
commit-time enforcement of exactly one active owner. Retirement tests cover
owner refusal plus membership archival and pending-transfer cancellation for
non-owners. Porsche dispatch tests cover membership commands without secret
echo. Deterministic multi-node overlap between full retirement, membership changes and
transfer acceptance now has scoped committed-action evidence; native shared
resource acceptance is tracked separately below.

## Implementation evidence

The [Teams domain](../../../marshall/lib/marshall/teams.ex) defines the
resources, with the transfer state machine in
[transfer.ex](../../../marshall/lib/marshall/teams/transfer.ex). Cedar
policies live in the [policy set](../../../marshall/priv/cedar/compute.cedar)
and [schema](../../../marshall/priv/cedar/schema.cedarschema); entity
construction extends [cedar.ex](../../../marshall/lib/marshall/authorization/cedar.ex).
The machine attribute is added by the migration in
[the Galileo migrations](../../../marshall/priv/repo/migrations) and team
commands are dispatched from
[commands.ex](../../../marshall/lib/marshall/ssh/commands.ex).
The [owner-invariant migration](../../../marshall/priv/repo/migrations/20260920090000_enforce_exactly_one_active_team_owner.exs)
rejects invalid legacy rows and installs deferred constraint triggers so creation
and ownership swaps may use temporary states while every committed active team
has one owner. [Account retirement](../../../marshall/lib/marshall/accounts/account_lifecycle.ex)
uses deterministic account/team locking, refuses current owners, and archives
memberships and pending transfers in the retirement transaction.
Team creation, membership changes and every ownership-transfer transition now
append payload-free `AdminEvent` receipts in the same transaction. Diagnostics
include the initiating actor where one exists; PaperTrail versions independently
retain the propagated actor metadata.

[Generated operation histories](../../../marshall/test/marshall/teams_history_test.exs)
now compare actual role and consent mutations with an independent model and check
deferred owner constraints between operations. The
[native browser journey](../../../nix/verification/tests/machines/teams/default.nix) exercises
committed ownership transfer and membership revocation through three ordinary
accounts over verified HTTPS. The [verification review](../reviews/2026-09-25-team-authority-verification.md)
records execution and a fixed admin-to-owner mutation refusal; neither test
presence nor the sandbox establishes distributed overlap.

Creation now reuses an active name only for its original creator who remains
current owner; other collisions refuse, while archived names acquire fresh
identities. [Creation histories](../../../marshall/test/marshall/teams_creation_test.exs)
and [three-node creation races](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
verify actor isolation, retry receipts and the committed owner invariant. The
[native browser](../../../nix/verification/tests/machines/teams/browser.py) verifies creation
refusals and fresh-name recovery with ordinary accounts.
The [creation review](../reviews/2026-09-25-team-creation-verification.md) records
execution and the separate SSH pinned-request replay boundary.

The [SSH HTTP histories](../../../marshall/test/marshall_web/teams_ssh_api_test.exs)
and [packaged Porsche journey](../../../nix/verification/tests/machines/team-ssh/driver.py)
exercise stable permanent refusals, consent, safe creator retries and pinned
historical requests without restoring membership. Public creation and stored
names share one grammar. The [SSH review](../reviews/2026-09-25-team-ssh-verification.md)
records corrections and exact execution scope; shared guest/integration access
and distributed transfer/retirement overlap remain separate obligations.

The [resource verification](../reviews/2026-09-25-team-resource-verification.md)
records a repair to member guest use: the old Cedar matrix admitted only reads,
contrary to this decision. Current members receive write for guest SSH, personal
terminals and existing profile-permitted agent use, including narrow prompt wake;
ordinary lifecycle and resource management remain owner/admin-only. Customer
owner-only access still precedes Cedar. [Generated resource histories](../../../marshall/test/marshall/teams_resource_history_test.exs)
exercise real resource actions and membership revocation; [full retirement races](../../../marshall/test/marshall/teams_retirement_distributed_test.exs)
use target-specific write gates across three independent Marshall nodes. The
[native resource journey](../../../nix/verification/tests/machines/team-resources/driver.py)
passed with actual certified Audi guest SSH and the Galileo private HTTP path.
It verifies ordinary member use and management refusal, Customer separation,
admin stop/start with retained home, and removal/re-addition of shared SSH and
integration access. Its captured source and remaining gaps are recorded in the
review; full Teams acceptance remains partial.

The [private browser verification](../reviews/2026-09-25-private-web-verification.md)
records a reproduced omission of team membership from Cedar's private web action.
The repaired rule admits current team member/admin web use without creating direct
grants or adding management authority; Customer guards and request-start leases
remain unchanged. Generated browser authorization/renewal histories and a dedicated
native team withdrawal journey distinguish application and transport evidence.
Accepted and partial status remain unchanged.

## Open questions

Independent physical hosts, terminal/agent-specific team journeys, existing SSH
session termination, public CLI integration configuration and production rollout
remain separate from the recorded shared-resource journey.

## Related decisions

- [ADR-0008](0008-identity-sharing-and-terminal.md): identity and sharing roots.
- [ADR-0018](0018-persisted-sharing-and-user-machine-access.md): per-machine grants.
- [ADR-0065](0065-passkey-administration.md): elevation unrelated to team roles.
- [ADR-0080](0080-named-edge-integrations.md): integrations owned by users or teams.

The [Galileo production review](../reviews/2026-10-02-galileo-production.md)
records the internal team archival action and correction of integration authority
that previously survived it. Generated direct/peer histories now refuse archived
owners despite retained memberships, without introducing public team deletion.
