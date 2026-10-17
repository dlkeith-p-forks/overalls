"""Replayable fixture identifiers drawn from Antithesis SDK decisions."""

from uuid import UUID

from core.interesting import choice

_HEX = tuple("0123456789abcdef")


def session_id() -> UUID:
    return UUID(hex="".join(choice(_HEX) for _ in range(32)), version=4)
