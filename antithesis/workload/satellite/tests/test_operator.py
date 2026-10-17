"""Only exact integration mutation receipts carry fixture authority."""

from unittest import TestCase
from uuid import UUID

from core.outcome import State
from satellite.operator import _result

REQUEST = UUID("11111111-1111-4111-8111-111111111111")
VM = UUID("22222222-2222-4222-8222-222222222222")
INTEGRATION = UUID("33333333-3333-4333-8333-333333333333")


class IntegrationReceiptTests(TestCase):
    def test_exact_attached_vm(self) -> None:
        raw = {
            "version": 1,
            "request_id": str(REQUEST),
            "operation": "integration.attach",
            "status": "ok",
            "value": {
                "integration_id": str(INTEGRATION),
                "name": "at-0123456789abcdef0123",
                "target": "A",
                "vm_id": str(VM),
                "attached": True,
            },
        }
        self.assertIs(_result(raw, REQUEST, "integration.attach", VM).state, State.OBSERVED)
        self.assertIs(
            _result(raw, REQUEST, "integration.attach", UUID(int=1)).state, State.UNAVAILABLE
        )

    def test_error_is_not_committed_receipt(self) -> None:
        self.assertIs(
            _result(
                {
                    "version": 1,
                    "request_id": str(REQUEST),
                    "operation": "integration.detach",
                    "status": "error",
                    "reason": "action_refused",
                },
                REQUEST,
                "integration.detach",
                VM,
            ).state,
            State.UNAVAILABLE,
        )
