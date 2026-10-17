"""Hegel property-based testing for NixOS machine tests.

Python frontend driving libhegel (Hegel's native engine, C ABI) from inside
the NixOS test driver. Public surface:

- `@given(...)`: value-level properties, executed per generated test case.
- `MachineStateMachine` + `@rule` + `@invariant`: engine-scheduled op
  sequences against live machines, with invariants checked at join points.
- `generators`: drawable specifications (`integers`, `text`, `lists`, ...).
- `tc.assume/note/event/target` inside test bodies for filtering and
  observability.
- `Pool`: previously produced values offered back for engine-chosen reuse.
"""

from hegel import generators
from hegel._lib import AssumptionRejected, HegelError, StopTest
from hegel.engine import EngineConfig, TestCase, replay_property, run_property
from hegel.generators import (
    Generator,
    binary,
    booleans,
    dates,
    datetimes,
    domains,
    emails,
    fixed_dictionaries,
    floats,
    from_regex,
    integers,
    ip_addresses,
    just,
    lists,
    one_of,
    optional,
    sampled_from,
    text,
    times,
    tuples,
    urls,
    uuids,
)
from hegel.runner import _run_registered, given
from hegel.statemachine import MachineStateMachine, Pool, WorkerContext, invariant, rule


def assume(condition: bool, reason: str = "") -> None:
    """Discard the current example when `condition` is false."""
    if not condition:
        raise AssumptionRejected(reason)


__all__ = [
    "AssumptionRejected",
    "EngineConfig",
    "Generator",
    "HegelError",
    "MachineStateMachine",
    "Pool",
    "StopTest",
    "TestCase",
    "WorkerContext",
    "_run_registered",
    "assume",
    "binary",
    "booleans",
    "dates",
    "datetimes",
    "domains",
    "emails",
    "fixed_dictionaries",
    "floats",
    "from_regex",
    "generators",
    "given",
    "integers",
    "invariant",
    "ip_addresses",
    "just",
    "lists",
    "one_of",
    "optional",
    "replay_property",
    "rule",
    "run_property",
    "sampled_from",
    "text",
    "times",
    "tuples",
    "urls",
    "uuids",
]
