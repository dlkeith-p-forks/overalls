"""SELECT-only account, token, and audit witnesses for browser authority."""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

from core.outcome import Observation, State
from core.sql import SqlOracle


@dataclass(frozen=True)
class Account:
    user_id: UUID
    administrator: bool
    mfa_enabled: bool
    generation: int
    deleted: bool


@dataclass(frozen=True)
class TokenInventory:
    magic: frozenset[str]
    user: frozenset[str]
    remember: frozenset[str]
    revoked: frozenset[str]


@dataclass(frozen=True)
class AdminInventory:
    target: Account
    audit_ids: frozenset[UUID]
    target_tokens: TokenInventory
    verification_ids: frozenset[str]


class AccessOracle:
    def __init__(self, sql: SqlOracle) -> None:
        self._sql = sql

    def account(self, email: str) -> Observation[Account | None]:
        rows = self._sql.select(
            "SELECT id, administrator, mfa_enabled, mfa_generation, deleted_at IS NOT NULL "
            "FROM users WHERE email = %s::citext",
            (email,),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if not rows.value:
            return Observation.observed(None)
        row = rows.value[0]
        if (
            len(row) != 5
            or not isinstance(row[0], UUID)
            or type(row[1]) is not bool
            or type(row[2]) is not bool
            or type(row[3]) is not int
            or type(row[4]) is not bool
        ):
            return Observation.unavailable()
        return Observation.observed(Account(row[0], row[1], row[2], row[3], row[4]))

    def token_jti(self, jti: str, purpose: str) -> Observation[bool]:
        rows = self._sql.select(
            "SELECT purpose, expires_at > clock_timestamp() FROM tokens WHERE jti = %s",
            (jti,),
            maximum_rows=1,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        if not rows.value:
            return Observation.observed(False)
        row = rows.value[0]
        if len(row) != 2 or not isinstance(row[0], str) or type(row[1]) is not bool:
            return Observation.unavailable()
        return Observation.observed(row[0] == purpose and row[1])

    def tokens(self, user_id: UUID) -> Observation[TokenInventory]:
        rows = self._sql.select(
            "SELECT purpose, jti FROM tokens WHERE subject = %s",
            (f"user?id={user_id}",),
            maximum_rows=256,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        groups: dict[str, set[str]] = {
            "magic_link": set(),
            "user": set(),
            "remember_me": set(),
            "revocation": set(),
        }
        for row in rows.value:
            if len(row) != 2 or not isinstance(row[0], str) or not isinstance(row[1], str):
                return Observation.unavailable()
            if row[0] in groups:
                groups[row[0]].add(row[1])
        return Observation.observed(
            TokenInventory(
                frozenset(groups["magic_link"]),
                frozenset(groups["user"]),
                frozenset(groups["remember_me"]),
                frozenset(groups["revocation"]),
            )
        )

    def verification_ids(self, user_id: UUID) -> Observation[frozenset[str]]:
        rows = self._sql.select(
            "SELECT id FROM account_verifications WHERE user_id = %s::uuid",
            (str(user_id),),
            maximum_rows=256,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        result: set[str] = set()
        for row in rows.value:
            if len(row) != 1 or not isinstance(row[0], str):
                return Observation.unavailable()
            result.add(row[0])
        return Observation.observed(frozenset(result))

    def completed_verifications(self, user_id: UUID) -> Observation[frozenset[str]]:
        rows = self._sql.select(
            "SELECT v.id FROM account_verifications v JOIN users u ON u.id = v.user_id "
            "JOIN account_passkeys p ON p.id = v.credential_id AND p.user_id = u.id "
            "WHERE v.user_id = %s::uuid AND v.generation = u.mfa_generation "
            "AND v.verified_at IS NOT NULL",
            (str(user_id),),
            maximum_rows=256,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        result: set[str] = set()
        for row in rows.value:
            if len(row) != 1 or not isinstance(row[0], str):
                return Observation.unavailable()
            result.add(row[0])
        return Observation.observed(frozenset(result))

    def elevated_verifications(self, user_id: UUID) -> Observation[frozenset[str]]:
        rows = self._sql.select(
            "SELECT v.id FROM account_verifications v JOIN users u ON u.id = v.user_id "
            "JOIN account_passkeys p ON p.id = v.credential_id AND p.user_id = u.id "
            "WHERE v.user_id = %s::uuid AND v.generation = u.mfa_generation "
            "AND v.verified_at IS NOT NULL AND v.elevated_until > clock_timestamp()",
            (str(user_id),),
            maximum_rows=256,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        result: set[str] = set()
        for row in rows.value:
            if len(row) != 1 or not isinstance(row[0], str):
                return Observation.unavailable()
            result.add(row[0])
        return Observation.observed(frozenset(result))

    def admin_inventory(self, actor_id: UUID, target_email: str) -> Observation[AdminInventory]:
        account = self.account(target_email)
        if account.state is not State.OBSERVED or account.value is None:
            return Observation.unavailable()
        token_inventory = self.tokens(account.value.user_id)
        verifications = self.verification_ids(account.value.user_id)
        if (
            token_inventory.state is not State.OBSERVED
            or token_inventory.value is None
            or verifications.state is not State.OBSERVED
            or verifications.value is None
        ):
            return Observation.unavailable()
        rows = self._sql.select(
            "SELECT id FROM account_admin_events WHERE actor_id = %s::uuid AND target_id = %s::uuid",
            (str(actor_id), str(account.value.user_id)),
            maximum_rows=256,
        )
        if rows.state is not State.OBSERVED or rows.value is None:
            return Observation.unavailable()
        ids: set[UUID] = set()
        for row in rows.value:
            if len(row) != 1 or not isinstance(row[0], UUID):
                return Observation.unavailable()
            ids.add(row[0])
        return Observation.observed(
            AdminInventory(
                account.value, frozenset(ids), token_inventory.value, verifications.value
            )
        )
