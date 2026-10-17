"""Property registry execution and reporting.

`_run_registered` drives every declared `@given` property and registered
`MachineStateMachine` through libhegel, in registration order, prints the
verdicts, and exits nonzero when any property fails — this is the epilogue
appended to properties-enabled test scripts by `nix/verification/hegel/run-test.nix`.
"""

from __future__ import annotations

import json
import os
import traceback
from collections.abc import Callable

from hegel import registry as _registry
from hegel.engine import (
    EngineConfig,
    RunReport,
    TestCase,
    replay_property,
    run_property,
)
from hegel.generators import Generator
from hegel.statemachine import execute_state_machine


def given(
    **parameter_gens: Generator[object],
) -> Callable[[Callable[..., None]], Callable[..., None]]:
    """Declare a value-level property.

    The decorated function is registered and executed once per engine-chosen
    test case with freshly drawn keyword arguments. It must raise (usually
    via assert) when the property does not hold; `tc.assume(...)` discards
    the current example.
    """

    def decorate(fn: Callable[..., None]) -> Callable[..., None]:
        _registry.REGISTRY.entries.append(
            _registry.Property(name=fn.__name__, fn=fn, parameter_gens=dict(parameter_gens))
        )
        return fn

    return decorate


def _report_lines(report: RunReport, redact: bool) -> list[str]:
    lines = [f"[hegel] {report.name}: {report.status.name} across {report.cases_run} test cases"]
    if report.error:
        lines.append(f"[hegel] {report.name}: run error: {report.error}")
    for failure in report.failures:
        lines.append(f"[hegel] {report.name}: counterexample origin {failure.origin}")
        if failure.blob and not redact:
            lines.append("[hegel] reproduce with:")
            lines.append(f"[hegel]   HEGEL_REPLAY_BLOB={json.dumps(failure.blob)}")
    if report.exception is not None:
        if redact:
            lines.append(
                f"[hegel] {report.name}: {type(report.exception).__name__} (values withheld: redacted)"
            )
        else:
            lines.extend(
                f"[hegel] {report.name}: {line}"
                for line in "".join(
                    traceback.format_exception(
                        type(report.exception), report.exception, report.exception.__traceback__
                    )
                ).splitlines()
            )
    return lines


def _run_registered(
    *,
    profile: str | None = "ci",
    test_cases: int | None = None,
    seed: int | None = None,
    derandomize: bool | None = None,
    database: str | None = None,
    stateful_step_count: int | None = None,
    suppress_health_checks: tuple[str, ...] = ("too_slow", "test_cases_too_large"),
    phases: tuple[str, ...] | None = None,
    show_statistics: bool | None = None,
    verbosity: str = "normal",
    redact: bool = False,
    sink: Callable[[str], None] = print,
) -> None:
    """Execute every registered property and state machine; exit 1 on failure.

    `HEGEL_REPLAY_BLOB` replays exactly one stored counterexample through all
    registered properties instead of running them (a blob is tied to the
    property whose choice sequence it encodes; unrelated properties simply
    do not reproduce it).
    """
    replay_blob = os.environ.get("HEGEL_REPLAY_BLOB")
    config = EngineConfig(
        profile=profile,
        test_cases=test_cases,
        seed=seed,
        derandomize=derandomize,
        database=database,
        suppress_health_checks=suppress_health_checks,
        phases=phases,
        show_statistics=show_statistics,
        verbosity=verbosity,
        print_blob=not redact,
    )

    units: list[tuple[str, Callable[[TestCase], None]]] = []
    for entry in _registry.REGISTRY.entries:
        if isinstance(entry, _registry.Property):
            units.append((entry.name, entry.body))
        else:
            steps = entry.steps if entry.steps is not None else stateful_step_count

            def stateful_body(
                entry: _registry.StatefulProperty = entry, steps: int | None = steps
            ) -> Callable[[TestCase], None]:
                def run(tc: TestCase) -> None:
                    execute_state_machine(
                        entry.machine_cls, tc, step_count=steps if steps is not None else 40
                    )

                return run

            units.append((entry.name, stateful_body()))

    if not units:
        sink("[hegel] no properties registered")
        return

    if replay_blob:
        for name, body in units:
            try:
                reproduced, error = replay_property(name, body, replay_blob, config)
            except Exception as replay_error:
                sink(f"[hegel] {name}: replay failed: {replay_error}")
                raise SystemExit(1) from replay_error
            if reproduced:
                sink(f"[hegel] {name}: replay reproduced the failure")
                if error is not None and not redact:
                    for line in "".join(
                        traceback.format_exception(type(error), error, error.__traceback__)
                    ).splitlines():
                        sink(f"[hegel] {name}: {line}")
                raise SystemExit(1)
        sink("[hegel] replay blob did not reproduce any registered failure")
        return

    failed: list[RunReport] = []
    for name, body in units:
        try:
            report = run_property(name, body, config, sink)
        except (KeyboardInterrupt, SystemExit, GeneratorExit):
            raise
        except BaseException as error:
            sink(f"[hegel] {name}: runner error: {type(error).__name__}: {error}")
            raise SystemExit(1) from error
        if report.status.name == "PASSED":
            sink(f"[hegel] {name}: PASSED ({report.cases_run} test cases)")
            continue
        # Reproduce the smallest failing blob to (re)capture the exception.
        if report.failures and report.failures[0].blob:
            reproduced, error = replay_property(name, body, report.failures[0].blob, config)
            if reproduced:
                report.exception = error
        failed.append(report)
        for line in _report_lines(report, redact):
            sink(line)

    if failed:
        names = ", ".join(report.name for report in failed)
        sink(f"[hegel] FAILED: {names}")
        raise SystemExit(1)
