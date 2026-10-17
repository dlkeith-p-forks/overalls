"""Bounded real-guest satellite histories with independent effect witnesses."""

import logging
import time
from uuid import UUID

from antithesis.assertions import always, reachable

from core.outcome import State
from satellite.guest import GuestProbe
from satellite.oracle import InferenceSnapshot, conserved
from satellite.origin import OriginReceipt, ReceiptSnapshot
from satellite.runtime import Runtime

LOG = logging.getLogger(__name__)


def _receipts(runtime: Runtime, cursor: int) -> ReceiptSnapshot | None:
    result = runtime.origin.receipts_after(cursor)
    return result.value if result.state is State.OBSERVED else None


def _snapshot(runtime: Runtime) -> InferenceSnapshot | None:
    result = runtime.inference.snapshot(runtime.vm.vm_id, runtime.vm.owner_id)
    return result.value if result.state is State.OBSERVED else None


def _new_requests(before: InferenceSnapshot, after: InferenceSnapshot) -> frozenset[UUID]:
    old = {row.request_id for row in before.completions}
    return frozenset(row.request_id for row in after.completions if row.request_id not in old)


def run_completion(runtime: Runtime) -> int:
    """@cc [owner:ghuntley,label:verification;accounting] satellite-settled-conservation
    A completion assertion MUST require a real guest request, its one durable
    provider accept, one new settled Marshall request and an exact Daily delta
    for this VM's isolated model bucket. Missing reads are unexercised.
    """
    before = _snapshot(runtime)
    cursor = runtime.origin.cursor()
    if before is None or cursor.state is not State.OBSERVED or cursor.value is None:
        return 0
    opened = GuestProbe.open(runtime.config, runtime.vm.vm_id)
    if opened.state is not State.OBSERVED or opened.value is None:
        LOG.info("satellite accounting unexercised: authenticated guest terminal unavailable")
        return 0
    guest = opened.value
    try:
        marker = runtime.origin.marker()
        if marker.state is not State.OBSERVED or marker.value is None:
            return 0
        if not runtime.origin.set_fault("openai", "normal"):
            return 0
        if not guest.submit_inference(marker.value):
            return 0
        terminal = guest.wait(marker.value)
        if terminal.state is not State.OBSERVED:
            return 0
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            after = _snapshot(runtime)
            receipts = _receipts(runtime, cursor.value)
            if after is not None and receipts is not None:
                request_ids = _new_requests(before, after)
                selected = tuple(row for row in after.completions if row.request_id in request_ids)
                effects = tuple(
                    row for row in receipts.for_marker(marker.value) if row.family == "openai"
                )
                if selected and all(row.completeness is not None for row in selected) and effects:
                    verdict = conserved(before, after, request_ids)
                    if verdict is not None:
                        reachable("Ziggy admitted real guest inference with provider acceptance")
                        always(
                            len(selected) == 1
                            and selected[0].model == guest.model
                            and len(effects) == 1
                            and verdict,
                            "Ziggy settled guest inference conserves one Marshall Daily update",
                        )
                        return 0
            time.sleep(0.5)
        LOG.info("satellite accounting unexercised: completion or effect did not settle")
        return 0
    finally:
        guest.close()


def _one_authorized_a(receipts: tuple[OriginReceipt, ...], route: str) -> bool:
    return len(receipts) == 1 and all(
        row.family == "integration"
        and row.route == route
        and row.origin == "a"
        and row.target_is_a is True
        and row.authorization_matches is True
        and row.static_header_matches is True
        for row in receipts
    )


def run_named_integration(runtime: Runtime) -> int:
    """Exercise current attachment, injected headers, withdrawal and reattachment."""
    created = runtime.integrations.call("integration.create")
    if created.state is not State.OBSERVED or created.value is None:
        return 0
    attached = runtime.integrations.call("integration.attach", runtime.vm.vm_id)
    if (
        attached.state is not State.OBSERVED
        or attached.value is None
        or attached.value.integration_id != created.value.integration_id
    ):
        return 0
    authority = runtime.authority.attached(created.value.integration_id, runtime.vm.vm_id)
    if authority.state is not State.OBSERVED or authority.value is not True:
        return 0
    opened = GuestProbe.open(runtime.config, runtime.vm.vm_id)
    if opened.state is not State.OBSERVED or opened.value is None:
        return 0
    guest = opened.value
    detached = False
    try:
        cursor = runtime.origin.cursor()
        marker = runtime.origin.marker()
        if (
            cursor.state is not State.OBSERVED
            or cursor.value is None
            or marker.state is not State.OBSERVED
            or marker.value is None
            or not runtime.origin.set_fault("integration", "normal")
            or not guest.submit_integration(
                created.value.name, marker.value, duplicate_headers=True
            )
        ):
            return 0
        response = guest.wait(marker.value)
        first = _receipts(runtime, cursor.value)
        if response.state is not State.OBSERVED or first is None:
            return 0
        effects = first.for_marker(marker.value)
        if not effects and response.value is not None and response.value.status != 200:
            return 0
        if effects:
            reachable("Galileo named request reached the independent origin")
        always(
            response.value is not None
            and response.value.status == 200
            and _one_authorized_a(effects, "probe"),
            "Galileo named request selected A and platform headers",
        )
        held_marker = runtime.origin.marker()
        held_cursor = runtime.origin.cursor()
        if (
            held_marker.state is not State.OBSERVED
            or held_marker.value is None
            or held_cursor.state is not State.OBSERVED
            or held_cursor.value is None
            or not runtime.origin.set_fault("integration", "hold")
            or not guest.submit_integration(created.value.name, held_marker.value, held=True)
        ):
            return 0
        held: OriginReceipt | None = None
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            current = _receipts(runtime, held_cursor.value)
            if current is not None:
                matches = current.for_marker(held_marker.value)
                if len(matches) == 1:
                    held = matches[0]
                    break
            time.sleep(0.2)
        if held is None or not _one_authorized_a((held,), "stream"):
            return 0
        held_state = runtime.origin.hold(held.sequence)
        if (
            held_state.state is not State.OBSERVED
            or held_state.value is None
            or held_state.value.state != "held"
        ):
            return 0
        removed = runtime.integrations.call("integration.detach", runtime.vm.vm_id)
        current_authority = runtime.authority.attached(
            created.value.integration_id, runtime.vm.vm_id
        )
        if (
            removed.state is not State.OBSERVED
            or removed.value is None
            or current_authority.state is not State.OBSERVED
            or current_authority.value is not False
        ):
            return 0
        detached = True
        reachable("Galileo named origin stream was open at committed detachment")
        last_hold = None
        last_hold_at = 0.0
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            observed = runtime.origin.hold(held.sequence)
            if observed.state is State.OBSERVED and observed.value is not None:
                last_hold = observed.value
                last_hold_at = time.monotonic()
                if observed.value.state == "eof" and observed.value.eof_observed is True:
                    break
            time.sleep(0.5)
        # An observed still-held socket after multiple renewal periods is a
        # negative witness; a missing origin read remains unexercised.
        hold_conclusive = last_hold is not None and time.monotonic() - last_hold_at <= 2
        if hold_conclusive and last_hold is not None:
            always(
                last_hold.state == "eof" and last_hold.eof_observed is True,
                "Galileo detached held origin stream closes before fixture deadline",
            )
        runtime.origin.set_fault("integration", "normal")
        fresh = GuestProbe.open(runtime.config, runtime.vm.vm_id)
        if fresh.state is not State.OBSERVED or fresh.value is None:
            return 0
        other_guest = fresh.value
        try:
            fresh_cursor = runtime.origin.cursor()
            fresh_marker = runtime.origin.marker()
            if (
                fresh_cursor.state is not State.OBSERVED
                or fresh_cursor.value is None
                or fresh_marker.state is not State.OBSERVED
                or fresh_marker.value is None
                or not other_guest.submit_integration(created.value.name, fresh_marker.value)
            ):
                return 0
            refused = other_guest.wait(fresh_marker.value)
            absent = _receipts(runtime, fresh_cursor.value)
            if refused.state is State.OBSERVED and refused.value is not None and absent is not None:
                if refused.value.status == 403 and not absent.for_marker(fresh_marker.value):
                    reachable("Galileo detached attachment refused a fresh named request")
                always(
                    refused.value.status == 403 and not absent.for_marker(fresh_marker.value),
                    "Galileo detached attachment blocks fresh upstream effect",
                )
                if refused.value.status != 403 or absent.for_marker(fresh_marker.value):
                    return 0
                restored = runtime.integrations.call("integration.attach", runtime.vm.vm_id)
                current_authority = runtime.authority.attached(
                    created.value.integration_id, runtime.vm.vm_id
                )
                if (
                    restored.state is not State.OBSERVED
                    or restored.value is None
                    or current_authority.state is not State.OBSERVED
                    or current_authority.value is not True
                ):
                    return 0
                detached = False
                restored_cursor = runtime.origin.cursor()
                restored_marker = runtime.origin.marker()
                if (
                    restored_cursor.state is not State.OBSERVED
                    or restored_cursor.value is None
                    or restored_marker.state is not State.OBSERVED
                    or restored_marker.value is None
                    or not other_guest.submit_integration(created.value.name, restored_marker.value)
                ):
                    return 0
                again = other_guest.wait(restored_marker.value)
                restored_effects = _receipts(runtime, restored_cursor.value)
                if (
                    again.state is State.OBSERVED
                    and again.value is not None
                    and restored_effects is not None
                ):
                    restored_ok = again.value.status == 200 and _one_authorized_a(
                        restored_effects.for_marker(restored_marker.value), "probe"
                    )
                    always(
                        restored_ok,
                        "Galileo reattached name resumes one authorized A effect",
                    )
        finally:
            other_guest.close()
        return 0
    finally:
        runtime.origin.set_fault("integration", "normal")
        if detached:
            runtime.integrations.call("integration.attach", runtime.vm.vm_id)
        guest.close()
