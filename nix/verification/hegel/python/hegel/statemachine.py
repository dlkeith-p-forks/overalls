"""Stateful (rule-based) property testing against live NixOS machines.

`MachineStateMachine` subclasses declare `@rule`s (engine-sequenced
operations) and `@invariant`s (checks libhegel schedules at join points).
libhegel picks which rule runs next; each test case is one op sequence,
shrunk to a minimal counterexample on failure.
"""

from __future__ import annotations

import contextvars
import threading
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from ctypes import byref, c_bool, c_char_p, c_double, c_int64, c_void_p
from dataclasses import dataclass
from typing import Any

from hegel import registry as _registry
from hegel._lib import (
    STATE_MACHINE_DONE,
    AssumptionRejected,
    check,
    lib,
)
from hegel.engine import TestCase
from hegel.generators import Generator

_ACTIVE_WORKER: contextvars.ContextVar[tuple[TestCase, int] | None] = contextvars.ContextVar(
    "hegel_active_worker", default=None
)


@dataclass(frozen=True)
class WorkerContext:
    """The test-case handle and stable index for the current rule worker."""

    test_case: TestCase
    index: int


@dataclass(frozen=True)
class RuleSpec:
    fn: Callable[..., Any]
    name: str
    weight: float
    group: int
    params: dict[str, Generator[object]]


@dataclass(frozen=True)
class InvariantSpec:
    fn: Callable[[Any], None]
    name: str
    always: bool


def rule(
    fn: Callable[..., Any] | None = None,
    *,
    weight: float = 1.0,
    group: int = 0,
    **params: Generator[Any],
) -> Callable[..., Any]:
    """Mark a method as an engine-scheduled rule.

    Keyword arguments are generators; each invocation draws fresh values.
    Runtime state is threaded with `self`; previously produced values can be
    offered back to the engine through `Pool`.
    """

    def decorate(function: Callable[..., Any]) -> Callable[..., Any]:
        function.__hegel_rule__ = RuleSpec(  # type: ignore[attr-defined]
            fn=function,
            name=function.__name__,
            weight=weight,
            group=group,
            params=params,
        )
        return function

    return decorate if fn is None else decorate(fn)


def invariant(
    fn: Callable[[Any], None] | None = None, *, always: bool = False
) -> Callable[[Any], None] | Callable[[Callable[[Any], None]], Callable[[Any], None]]:
    """Mark a method as an invariant. `always=True` checks it at every
    join point; otherwise libhegel samples it (probability 1/step_count).
    Initial and final states are always checked for every invariant."""

    def decorate(function: Callable[[Any], None]) -> Callable[[Any], None]:
        function.__hegel_invariant__ = InvariantSpec(  # type: ignore[attr-defined]
            fn=function, name=function.__name__, always=always
        )
        return function

    return decorate if fn is None else decorate(fn)


class Pool:
    """An engine-managed pool of previously produced values.

    `pool.add(value)` records a value and returns its engine-chosen variable
    id; `pool.draw()` has libhegel pick (and shrink towards) a previously
    added id. Keep the id → value mapping yourself. Bounds: draw raises
    AssumptionRejected when the pool is empty, which rejects the current
    rule (it does not fail the test).
    """

    def __init__(self) -> None:
        self._handle: int | None = None
        self._tc: TestCase | None = None
        self._values: dict[int, object] = {}
        self._lock = threading.RLock()

    def _active_test_case(self) -> TestCase:
        active = _ACTIVE_WORKER.get()
        return active[0] if active is not None else self._tc  # type: ignore[return-value]

    def _bind(self, tc: TestCase) -> None:
        engine = lib()
        handle = c_void_p()
        check(engine.hegel_new_pool(engine.ctx, tc._ptr, byref(handle)))
        assert handle.value is not None
        self._handle = int(handle.value)
        self._tc = tc

    def _release(self) -> None:
        if self._handle is not None:
            engine = lib()
            engine.hegel_pool_free(engine.ctx, self._handle)
            self._handle = None
            self._tc = None

    def add(self, value: object) -> int:
        if self._handle is None or self._tc is None:
            raise RuntimeError("Pool is only usable while a state machine test case runs")
        engine = lib()
        tc = self._active_test_case()
        out = c_int64()
        with self._lock:
            check(engine.hegel_pool_add(engine.ctx, tc._ptr, self._handle, byref(out)))
            self._values[int(out.value)] = value
        return int(out.value)

    def draw[T](self, *, consume: bool = False) -> T:
        if self._handle is None or self._tc is None:
            raise RuntimeError("Pool is only usable while a state machine test case runs")
        engine = lib()
        tc = self._active_test_case()
        out = c_int64()
        with self._lock:
            check(
                engine.hegel_pool_generate(engine.ctx, tc._ptr, self._handle, consume, byref(out))
            )
            if int(out.value) not in self._values:
                raise AssumptionRejected("pool variable no longer available")
            value = self._values[int(out.value)]
            if consume:
                del self._values[int(out.value)]
        return value


class MachineStateMachine:
    """Base class for stateful machine tests.

    Subclass, declare `@rule` methods (the operations) and `@invariant`
    methods (the properties), optionally override `setup`/`teardown`, then
    register with `MyMachine.run()`. Execution runs each engine-chosen op
    sequence against live machines; engine-side shrinking minimizes failing
    sequences.
    """

    def setup(self) -> None:
        """Prepare state before the op sequence (called once per test case)."""

    def teardown(self) -> None:
        """Release per-case state (called once per test case, on all paths)."""

    @classmethod
    def _rules(cls) -> list[RuleSpec]:
        specs = [
            member.__hegel_rule__
            for member in vars(cls).values()
            if hasattr(member, "__hegel_rule__")
        ]
        return sorted(specs, key=lambda spec: spec.name)

    @classmethod
    def _invariants(cls) -> list[InvariantSpec]:
        specs = [
            member.__hegel_invariant__
            for member in vars(cls).values()
            if hasattr(member, "__hegel_invariant__")
        ]
        return sorted(specs, key=lambda spec: spec.name)

    @classmethod
    def run(
        cls,
        *,
        steps: int | None = None,
        min_concurrency: int = 1,
        max_concurrency: int = 1,
    ) -> None:
        """Register this machine as a stateful property for `_run_registered`."""
        if steps is not None and steps <= 0:
            raise ValueError("run(steps=) must be a positive step count")
        if min_concurrency < 1 or max_concurrency < min_concurrency:
            raise ValueError("run concurrency must satisfy 1 <= min_concurrency <= max_concurrency")
        _registry.REGISTRY.entries.append(
            _registry.StatefulProperty(
                name=cls.__name__,
                machine_cls=cls,
                steps=steps,
                min_concurrency=min_concurrency,
                max_concurrency=max_concurrency,
            )
        )

    @property
    def worker(self) -> WorkerContext | None:
        """Return the current worker context while a rule is executing."""
        active = _ACTIVE_WORKER.get()
        return WorkerContext(*active) if active is not None else None


def _pools_of(instance: MachineStateMachine) -> list[Pool]:
    return [value for value in vars(instance).values() if isinstance(value, Pool)]


def execute_state_machine(
    machine_cls: type[MachineStateMachine],
    tc: TestCase,
    *,
    step_count: int,
    min_concurrency: int = 1,
    max_concurrency: int = 1,
) -> None:
    """One stateful test case: setup, engine-driven rule loop, guaranteed
    invariant checks at initial/final/join points, teardown."""
    engine = lib()
    instance = machine_cls()
    worker_cases: list[TestCase] = []
    try:
        instance.setup()
        pools = _pools_of(instance)
        for pool in pools:
            pool._bind(tc)
        rules = machine_cls._rules()
        invariants = machine_cls._invariants()
        if not rules:
            raise ValueError(f"{machine_cls.__name__} declares no @rule methods")
        for spec in invariants:
            spec.fn(instance)

        rule_names = (c_char_p * len(rules))(*[spec.name.encode() for spec in rules])
        rule_groups = (c_int64 * len(rules))(*[spec.group for spec in rules])
        rule_weights = (c_double * len(rules))(*[spec.weight for spec in rules])
        invariant_names = (c_char_p * len(invariants))(*[spec.name.encode() for spec in invariants])
        invariant_always = (c_bool * len(invariants))(*[spec.always for spec in invariants])
        sm = c_void_p()
        out_concurrency = c_int64()
        check(
            engine.hegel_new_state_machine(
                engine.ctx,
                tc._ptr,
                rule_names,
                rule_groups,
                rule_weights,
                len(rules),
                invariant_names,
                invariant_always,
                len(invariants),
                min_concurrency,
                max_concurrency,
                step_count,
                byref(sm),
                byref(out_concurrency),
            )
        )
        assert sm.value is not None
        worker_count = int(out_concurrency.value)
        worker_cases = [tc]
        if worker_count > 1:
            for index in range(1, worker_count):
                worker_cases.append(tc.clone(worker_index=index))

        def run_worker(index: int) -> None:
            worker_tc = worker_cases[index]
            token = _ACTIVE_WORKER.set((worker_tc, index))
            try:
                while True:
                    rule_index = c_int64()
                    check(
                        engine.hegel_state_machine_next_rule(
                            engine.ctx, worker_tc._ptr, sm, index, byref(rule_index)
                        )
                    )
                    if rule_index.value == STATE_MACHINE_DONE:
                        return
                    spec = rules[rule_index.value]
                    try:
                        values = {name: worker_tc.draw(gen) for name, gen in spec.params.items()}
                        spec.fn(instance, **values)
                    except AssumptionRejected:
                        check(
                            engine.hegel_state_machine_rule_rejected(
                                engine.ctx, worker_tc._ptr, sm, index
                            )
                        )
            finally:
                _ACTIVE_WORKER.reset(token)

        try:
            while True:
                group = c_int64()
                check(engine.hegel_state_machine_next_group(engine.ctx, tc._ptr, sm, byref(group)))
                if group.value == STATE_MACHINE_DONE:
                    break
                for index, spec in enumerate(invariants):
                    should = c_bool(True)
                    if not spec.always:
                        check(
                            engine.hegel_state_machine_should_check_invariant(
                                engine.ctx, tc._ptr, sm, index, byref(should)
                            )
                        )
                    if should.value:
                        spec.fn(instance)
                if worker_count == 1:
                    run_worker(0)
                else:
                    with ThreadPoolExecutor(max_workers=worker_count) as executor:
                        futures = [
                            executor.submit(run_worker, index) for index in range(worker_count)
                        ]
                        for future in futures:
                            future.result()
            for spec in invariants:
                spec.fn(instance)
        finally:
            engine.hegel_state_machine_free(engine.ctx, sm)
    finally:
        try:
            instance.teardown()
        finally:
            for worker_tc in worker_cases[1:]:
                worker_tc.close()
            for pool in _pools_of(instance):
                pool._release()
