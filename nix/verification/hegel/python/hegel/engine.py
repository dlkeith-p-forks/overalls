"""Engine handles and the property run loop over libhegel.

- `EngineConfig`: resolved settings for one run (maps onto `hegel_settings_t`).
- `TestCase`: the public per-case handle; test bodies draw from it.
- `run_property` / `replay_property`: the run lifecycle. The caller supplies
  the test body; outcomes are reported by printing `sink` lines and returned
  as a `RunReport`.
"""

from __future__ import annotations

import ctypes
import pathlib
import traceback
from collections.abc import Callable
from ctypes import byref, c_char_p, c_size_t, c_uint8, c_void_p
from dataclasses import dataclass
from typing import TYPE_CHECKING, TypeVar

from hegel._lib import (
    HEALTH_CHECKS,
    PHASES,
    VERBOSITY,
    AssumptionRejected,
    CaseStatus,
    OutputCallback,
    RunStatus,
    StopTest,
    check,
    lib,
)

if TYPE_CHECKING:
    from hegel.generators import Generator

T = TypeVar("T")

_FATAL = (KeyboardInterrupt, SystemExit, GeneratorExit)
_PACKAGE_DIR = pathlib.Path(__file__).resolve().parent


def _bytes(value: str) -> bytes:
    return value.encode("utf-8")


@dataclass(frozen=True)
class EngineConfig:
    """Resolved settings applied over a libhegel profile per run."""

    profile: str | None = "ci"
    test_cases: int | None = None
    seed: int | None = None
    derandomize: bool | None = None
    database: str | None = None
    database_key: str | None = None
    suppress_health_checks: tuple[str, ...] = ("too_slow", "test_cases_too_large")
    phases: tuple[str, ...] | None = None
    report_multiple_failures: bool = True
    show_statistics: bool | None = None
    verbosity: str = "normal"
    print_blob: bool = True

    def build(self) -> int:
        engine = lib()
        out = c_void_p()
        if self.profile is None:
            check(engine.hegel_settings_new(engine.ctx, byref(out)))
        else:
            check(
                engine.hegel_settings_new_for_profile(engine.ctx, _bytes(self.profile), byref(out))
            )
        settings_raw = out.value
        assert settings_raw is not None
        settings = int(settings_raw)
        try:
            if self.test_cases is not None:
                check(
                    engine.hegel_settings_set_test_cases(
                        engine.ctx, settings, ctypes.c_uint64(self.test_cases)
                    )
                )
            if self.seed is not None:
                check(
                    engine.hegel_settings_set_seed(
                        engine.ctx, settings, ctypes.c_uint64(self.seed), True
                    )
                )
            if self.derandomize is not None:
                check(engine.hegel_settings_set_derandomize(engine.ctx, settings, self.derandomize))
            if self.database is not None:
                check(
                    engine.hegel_settings_set_database(engine.ctx, settings, _bytes(self.database))
                )
            if self.database_key is not None:
                check(
                    engine.hegel_settings_set_database_key(
                        engine.ctx, settings, _bytes(self.database_key)
                    )
                )
            mask = 0
            for name in self.suppress_health_checks:
                mask |= HEALTH_CHECKS[name]
            if mask:
                check(
                    engine.hegel_settings_set_suppress_health_check(
                        engine.ctx, settings, ctypes.c_uint(mask)
                    )
                )
            if self.phases is not None:
                phases_mask = 0
                for name in self.phases:
                    phases_mask |= PHASES[name]
                check(
                    engine.hegel_settings_set_phases(
                        engine.ctx, settings, ctypes.c_uint(phases_mask)
                    )
                )
            check(
                engine.hegel_settings_set_report_multiple_failures(
                    engine.ctx, settings, self.report_multiple_failures
                )
            )
            if self.show_statistics is not None:
                check(
                    engine.hegel_settings_set_show_statistics(
                        engine.ctx, settings, self.show_statistics
                    )
                )
            check(
                engine.hegel_settings_set_verbosity(
                    engine.ctx, settings, ctypes.c_uint(VERBOSITY[self.verbosity])
                )
            )
            check(engine.hegel_settings_set_print_blob(engine.ctx, settings, self.print_blob))
        except BaseException:
            engine.hegel_settings_free(engine.ctx, settings)
            raise
        return settings


class TestCase:
    """One execution of a test body; draws generated values from libhegel."""

    def __init__(self, ptr: int) -> None:
        self._ptr = ptr

    def draw(self, generator: Generator[T]) -> T:
        return generator.draw(self)

    def note(self, message: str) -> None:
        engine = lib()
        data = _bytes(message)
        buffer = (c_uint8 * len(data)).from_buffer_copy(data)
        check(engine.hegel_note(engine.ctx, self._ptr, buffer, len(data)))

    def assume(self, condition: bool, reason: str = "") -> None:
        if not condition:
            raise AssumptionRejected(reason)

    def event(self, label: str) -> None:
        engine = lib()
        check(engine.hegel_event(engine.ctx, self._ptr, _bytes(label)))

    def event_value(self, label: str, value: float) -> None:
        engine = lib()
        check(engine.hegel_event_value(engine.ctx, self._ptr, value, _bytes(label)))

    def target(self, value: float, label: str) -> None:
        engine = lib()
        check(engine.hegel_target(engine.ctx, self._ptr, value, _bytes(label)))


@dataclass
class Failure:
    origin: str
    blob: str | None


@dataclass
class RunReport:
    name: str
    status: RunStatus
    cases_run: int
    failures: list[Failure]
    error: str | None = None
    # The exception re-captured by replaying the minimal failing blob, when
    # one exists; never includes drawn values when the caller redacts.
    exception: BaseException | None = None


def _origin_for(name: str, error: BaseException) -> str:
    """Stable per-bug origin: the innermost assertion site of the test code.

    NixOS test scripts are exec'd ("<string>" frames); real files fall back to
    the innermost frame outside the hegel package itself.
    """
    frames = traceback.extract_tb(error.__traceback__) if error.__traceback__ else []
    test_frames = [f for f in frames if f.filename == "<string>"]
    if test_frames:
        frame = test_frames[-1]
        return f"{name}::<string>:{frame.lineno}"
    ours = [f for f in frames if _PACKAGE_DIR not in pathlib.Path(f.filename).resolve().parents]
    if ours:
        frame = ours[-1]
        return f"{name}::{pathlib.Path(frame.filename).name}:{frame.lineno}"
    return f"{name}::{type(error).__name__}"


def _run_body(
    name: str, body: Callable[[TestCase], None], raw_ptr: int
) -> tuple[int, str | None, BaseException | None]:
    test_case = TestCase(raw_ptr)
    try:
        body(test_case)
    except AssumptionRejected:
        return int(CaseStatus.INVALID), None, None
    except StopTest:
        return int(CaseStatus.OVERRUN), None, None
    except _FATAL as error:  # completed as INVALID, then re-raised by the run loop
        return int(CaseStatus.INVALID), None, error
    except BaseException as error:
        return int(CaseStatus.INTERESTING), _origin_for(name, error), error
    return int(CaseStatus.VALID), None, None


def _failure_list(result_ptr: int) -> list[Failure]:
    engine = lib()
    count = c_size_t()
    check(engine.hegel_run_result_failure_count(engine.ctx, result_ptr, byref(count)))
    failures: list[Failure] = []
    for index in range(count.value):
        failure_ptr = c_void_p()
        check(engine.hegel_run_result_failure(engine.ctx, result_ptr, index, byref(failure_ptr)))
        try:
            origin = c_char_p()
            blob = c_char_p()
            check(engine.hegel_failure_origin(engine.ctx, failure_ptr, byref(origin)))
            check(engine.hegel_failure_reproduction_blob(engine.ctx, failure_ptr, byref(blob)))
            failures.append(
                Failure(
                    origin=origin.value.decode() if origin.value else "<unknown>",
                    blob=blob.value.decode() if blob.value else None,
                )
            )
        finally:
            engine.hegel_failure_free(engine.ctx, failure_ptr)
    return failures


def run_property(
    name: str,
    body: Callable[[TestCase], None],
    config: EngineConfig,
    sink: Callable[[str], None] = print,
) -> RunReport:
    """Run one property to a verdict: generation, then shrinking on failure."""
    engine = lib()
    settings = config.build()

    def on_output(_user_data: object, line: object, length: int) -> None:
        sink(ctypes.string_at(line, length).decode("utf-8", errors="replace"))

    callback = OutputCallback(on_output)
    run = c_void_p()
    try:
        check(engine.hegel_run_start(engine.ctx, settings, callback, None, byref(run)))
    finally:
        engine.hegel_settings_free(engine.ctx, settings)

    cases = 0
    try:
        while True:
            raw = c_void_p()
            check(engine.hegel_next_test_case(engine.ctx, run, byref(raw)))
            if not raw.value:
                break
            try:
                status, origin, _error = _run_body(name, body, int(raw.value))
                check(
                    engine.hegel_mark_complete(
                        engine.ctx, raw, status, _bytes(origin) if origin else None
                    )
                )
            finally:
                engine.hegel_test_case_free(engine.ctx, raw)
            if isinstance(_error, _FATAL):
                raise _error
            if status == int(CaseStatus.VALID):
                cases += 1
        result = c_void_p()
        try:
            check(engine.hegel_run_result(engine.ctx, run, byref(result)))
            status_out = ctypes.c_int()
            check(engine.hegel_run_result_status(engine.ctx, result, byref(status_out)))
            error_out = c_char_p()
            check(engine.hegel_run_result_error(engine.ctx, result, byref(error_out)))
            failures = _failure_list(result)
            report = RunReport(
                name=name,
                status=RunStatus(status_out.value),
                cases_run=cases,
                failures=failures,
                error=error_out.value.decode() if error_out.value else None,
            )
        finally:
            if result.value:
                engine.hegel_run_result_free(engine.ctx, result)
    finally:
        engine.hegel_run_free(engine.ctx, run)
    return report


def replay_property(
    name: str,
    body: Callable[[TestCase], None],
    blob: str,
    config: EngineConfig,
) -> tuple[bool, BaseException | None]:
    """Replay one counterexample blob; return (reproduced, exception)."""
    engine = lib()

    def on_output(_user_data: object, _line: object, _length: int) -> None:
        return None

    callback = OutputCallback(on_output)
    settings = config.build()
    raw = c_void_p()
    try:
        check(
            engine.hegel_test_case_from_blob(
                engine.ctx, settings, _bytes(blob), callback, None, byref(raw)
            )
        )
        status, origin, error = _run_body(name, body, int(raw.value))
        check(
            engine.hegel_mark_complete(engine.ctx, raw, status, _bytes(origin) if origin else None)
        )
    finally:
        if raw.value:
            engine.hegel_test_case_free(engine.ctx, raw)
        engine.hegel_settings_free(engine.ctx, settings)
    return status == int(CaseStatus.INTERESTING), error
