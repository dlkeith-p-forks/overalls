"""Read-only Marshall inference snapshots; an unavailable read never means zero."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import TYPE_CHECKING
from uuid import UUID

from core.outcome import Observation, State

if TYPE_CHECKING:
    from core.sql import SqlOracle


@dataclass(frozen=True)
class Completion:
    request_id: UUID
    owner_id: UUID
    host_id: UUID
    provider: str
    model: str
    day: str
    outcome: str | None
    completeness: str | None
    input_tokens: int | None
    output_tokens: int | None


@dataclass(frozen=True)
class Daily:
    day: str
    owner_id: UUID
    provider: str
    model: str
    requests: int
    unknown_requests: int
    input_tokens: Decimal
    output_tokens: Decimal


@dataclass(frozen=True)
class InferenceSnapshot:
    completions: tuple[Completion, ...]
    daily: tuple[Daily, ...]

    def bucket(self, day: str, owner_id: UUID, provider: str, model: str) -> Daily:
        matching = tuple(
            row
            for row in self.daily
            if (row.day, row.owner_id, row.provider, row.model) == (day, owner_id, provider, model)
        )
        if len(matching) > 1:
            raise ValueError("duplicate accounting bucket")
        if matching:
            return matching[0]
        return Daily(day, owner_id, provider, model, 0, 0, Decimal(0), Decimal(0))


class InferenceOracle:
    def __init__(self, sql: SqlOracle) -> None:
        self._sql = sql

    def snapshot(self, vm_id: UUID, owner_id: UUID) -> Observation[InferenceSnapshot]:
        """@cc [owner:ghuntley,label:verification;accounting] inference-same-statement-snapshot
        Requests and Daily rows MUST be read in one PostgreSQL statement. A
        failed/oversized/invalid result MUST remain unavailable, never a zero
        contribution. Workload assertions MUST compare one isolated bucket's
        delta with settled completion projections.
        """
        result = self._sql.select(
            "SELECT 'request', r.id::text, r.owner_id::text, r.host_id::text, "
            "r.provider, r.model, r.inserted_at::date::text, r.completion, "
            "NULL::bigint, NULL::bigint, NULL::numeric, NULL::numeric "
            "FROM inference_requests r WHERE r.vm_id = %s::uuid "
            "UNION ALL "
            "SELECT 'daily', NULL::text, d.owner_id::text, NULL::text, "
            "d.provider, d.model, d.day::text, NULL::jsonb, "
            "d.requests, d.unknown_requests, d.input_tokens, d.output_tokens "
            "FROM inference_daily d WHERE d.owner_id = %s::uuid",
            (str(vm_id), str(owner_id)),
            maximum_rows=2048,
        )
        if result.state is not State.OBSERVED or result.value is None:
            return Observation.unavailable()
        completions: list[Completion] = []
        daily: list[Daily] = []
        try:
            for row in result.value:
                if len(row) != 12:
                    return Observation.unavailable()
                kind, raw_id, raw_owner, raw_host, provider, model, day, raw_completion = row[:8]
                if (
                    not isinstance(raw_owner, str)
                    or not isinstance(provider, str)
                    or provider not in ("openai", "anthropic")
                    or not isinstance(model, str)
                    or not isinstance(day, str)
                ):
                    return Observation.unavailable()
                bucket_owner = UUID(raw_owner)
                if kind == "request":
                    if not isinstance(raw_id, str) or not isinstance(raw_host, str):
                        return Observation.unavailable()
                    outcome: str | None = None
                    completeness: str | None = None
                    input_tokens: int | None = None
                    output_tokens: int | None = None
                    if raw_completion is not None:
                        if not isinstance(raw_completion, dict):
                            return Observation.unavailable()
                        outcome = raw_completion.get("outcome")
                        completeness = raw_completion.get("completeness")
                        tokens = raw_completion.get("tokens")
                        if (
                            not isinstance(outcome, str)
                            or completeness not in ("complete", "partial", "unknown")
                            or not isinstance(tokens, dict)
                        ):
                            return Observation.unavailable()
                        input_tokens = _token(tokens.get("input_tokens"))
                        output_tokens = _token(tokens.get("output_tokens"))
                        if completeness == "unknown" and (
                            input_tokens is not None or output_tokens is not None
                        ):
                            return Observation.unavailable()
                    completions.append(
                        Completion(
                            UUID(raw_id),
                            bucket_owner,
                            UUID(raw_host),
                            provider,
                            model,
                            day,
                            outcome,
                            completeness,
                            input_tokens,
                            output_tokens,
                        )
                    )
                elif kind == "daily":
                    requests, unknown, input_sum, output_sum = row[8:]
                    if (
                        type(requests) is not int
                        or type(unknown) is not int
                        or requests < 0
                        or not 0 <= unknown <= requests
                        or not isinstance(input_sum, Decimal)
                        or not isinstance(output_sum, Decimal)
                    ):
                        return Observation.unavailable()
                    daily.append(
                        Daily(
                            day,
                            bucket_owner,
                            provider,
                            model,
                            requests,
                            unknown,
                            input_sum,
                            output_sum,
                        )
                    )
                else:
                    return Observation.unavailable()
        except (TypeError, ValueError):
            return Observation.unavailable()
        return Observation.observed(InferenceSnapshot(tuple(completions), tuple(daily)))


def _token(value: object) -> int | None:
    if value is None:
        return None
    if type(value) is not int or value < 0:
        raise ValueError("invalid token count")
    return value


def conserved(
    before: InferenceSnapshot,
    after: InferenceSnapshot,
    request_ids: frozenset[UUID],
) -> bool | None:
    """Return a verdict only after every selected immutable request is completed.

    The dedicated fixture owner/model makes the Daily bucket exclusive to this
    workload. A foreign completion or extra writer therefore produces a mismatch.
    """
    selected = tuple(row for row in after.completions if row.request_id in request_ids)
    if len(selected) != len(request_ids) or any(row.completeness is None for row in selected):
        return None
    if not selected:
        return None
    first = selected[0]
    if any(
        (row.day, row.owner_id, row.provider, row.model)
        != (first.day, first.owner_id, first.provider, first.model)
        for row in selected
    ):
        return None
    if any(row.request_id in request_ids for row in before.completions):
        return None
    earlier = {row.request_id for row in before.completions if row.completeness is not None}
    other_new = {
        row.request_id
        for row in after.completions
        if row.completeness is not None and row.request_id not in earlier | request_ids
    }
    if other_new:
        return None
    try:
        start = before.bucket(first.day, first.owner_id, first.provider, first.model)
        end = after.bucket(first.day, first.owner_id, first.provider, first.model)
    except ValueError:
        return None
    unknown = sum(row.completeness != "complete" for row in selected)
    input_tokens = sum(row.input_tokens or 0 for row in selected)
    output_tokens = sum(row.output_tokens or 0 for row in selected)
    return (
        end.requests - start.requests == len(selected)
        and end.unknown_requests - start.unknown_requests == unknown
        and end.input_tokens - start.input_tokens == Decimal(input_tokens)
        and end.output_tokens - start.output_tokens == Decimal(output_tokens)
    )
