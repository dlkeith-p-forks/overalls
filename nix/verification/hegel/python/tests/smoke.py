"""Smoke properties for the overalls hegel binding package checkPhase.

Modes: "passing" (must exit 0), "state" (state machine, must exit 0),
"value_failing" / "state_failing" (must exit 1 with a FAILED line and a
reproduce blob for the value case).
"""

import sys

from hegel import (
    MachineStateMachine,
    Pool,
    TestCase,
    _run_registered,
    given,
    integers,
    invariant,
    lists,
    rule,
)

MODE = sys.argv[1] if len(sys.argv) > 1 else "passing"


@given(xs=lists(integers(), max_size=8))
def sorted_idempotent(tc: TestCase, xs: list[int]) -> None:
    assert sorted(sorted(xs)) == sorted(xs)


@given(n=integers())
def too_big(tc: TestCase, n: int) -> None:
    if MODE == "value_failing":
        assert n < 5


class CounterMachine(MachineStateMachine):
    def setup(self) -> None:
        self.count = 0
        self.seen: Pool = Pool()
        self.peak = 0

    @rule(weight=3, amount=integers(1, 10))
    def bump(self, amount: int) -> None:
        self.count += amount
        self.seen.add(self.count)
        self.peak = max(self.peak, self.count)

    @rule(weight=1)
    def reset(self) -> None:
        self.count = 0

    @invariant(always=True)
    def never_negative(self) -> None:
        assert self.count >= 0

    @invariant
    def peak_above_zero(self) -> None:
        # Deliberately fragile: fails if a case never bumps the counter.
        if MODE == "state_failing":
            assert self.peak > 0


if MODE in ("state", "state_failing"):
    CounterMachine.run(steps=20)

if MODE in ("value_failing", "state_failing"):
    _run_registered(profile="development", test_cases=200, sink=print)
else:
    _run_registered(profile="development", sink=print)
