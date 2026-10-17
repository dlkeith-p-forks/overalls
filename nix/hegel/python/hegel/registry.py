"""Process-wide registry of declared properties.

`hegel.given` registers value-level properties; `MachineStateMachine.run`
registers stateful ones. `hegel.runner._run_registered` executes them in
registration order. Module-level so `@given` in a test script and the
runner epilogue share one registry.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from hegel.engine import TestCase
    from hegel.generators import Generator
    from hegel.statemachine import MachineStateMachine


@dataclass
class Property:
    name: str
    fn: Callable[..., None]
    parameter_gens: dict[str, Generator[object]]

    def body(self, tc: TestCase) -> None:
        values = {name: tc.draw(gen) for name, gen in self.parameter_gens.items()}
        self.fn(tc, **values)


@dataclass
class StatefulProperty:
    name: str
    machine_cls: type[MachineStateMachine]
    steps: int | None


Entry = Property | StatefulProperty


@dataclass
class Registry:
    entries: list[Entry] = field(default_factory=list)

    def clear(self) -> None:
        self.entries.clear()


REGISTRY = Registry()
