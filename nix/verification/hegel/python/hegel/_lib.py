"""Low-level ctypes bindings for libhegel_c, Hegel's native PBT engine.

The ABI is defined by the vendored `nix/verification/hegel/hegel.h` (a copy of
`hegel-c/include/hegel.h` from hegeldev/hegel-rust). The library path is
substituted at package build time with the pinned `libhegel` store path;
`HEGEL_LIBRARY_PATH` overrides it for development outside Nix.
"""

from __future__ import annotations

import atexit
import ctypes
import os
import threading
from collections.abc import Callable
from ctypes import (
    POINTER,
    c_bool,
    c_char_p,
    c_double,
    c_int64,
    c_size_t,
    c_uint8,
    c_uint32,
    c_uint64,
    c_void_p,
)
from enum import IntEnum

_DEFAULT_LIBRARY = "@LIBHEGEL_C@"

# A context owns the ABI's last-error slot and cannot be used concurrently.
# Worker threads use cloned test-case handles, while this lock serialises the
# short ctypes calls that touch the shared context.
_ENGINE_LOCK = threading.RLock()


class Result(IntEnum):
    OK = 0
    STOP_TEST = -1
    ASSUME = -2
    BACKEND = -3
    INVALID_HANDLE = -4
    INVALID_ARG = -5
    ALREADY_COMPLETE = -6
    NOT_COMPLETE = -7
    INTERNAL = -8
    CONCURRENT_USE = -9
    RETRY = -10


class RunStatus(IntEnum):
    PASSED = 0
    FAILED = 1
    ERROR = 2
    FAILED_NONDETERMINISTIC = 3


class CaseStatus(IntEnum):
    VALID = 0
    INVALID = 1
    OVERRUN = 2
    INTERESTING = 3


STATE_MACHINE_DONE = -(2**63)

HEALTH_CHECKS: dict[str, int] = {
    "filter_too_much": 1 << 0,
    "too_slow": 1 << 1,
    "test_cases_too_large": 1 << 2,
    "large_initial_test_case": 1 << 3,
}

PHASES: dict[str, int] = {
    "explicit": 1 << 0,
    "reuse": 1 << 1,
    "generate": 1 << 2,
    "target": 1 << 3,
    "shrink": 1 << 4,
}

VERBOSITY: dict[str, int] = {"normal": 0, "quiet": 1, "verbose": 2, "debug": 3}


class HegelError(Exception):
    """A libhegel call failed; carries the result code and engine message."""

    def __init__(self, code: int, message: str) -> None:
        self.code = code
        known = Result._value2member_map_.get(code)
        name = known.name if known is not None else "UNKNOWN"
        super().__init__(f"libhegel error {name}({code}): {message}")


class StopTest(Exception):
    """libhegel exhausted the choice budget for the current test case."""


class AssumptionRejected(Exception):
    """The current test case must be discarded (failed assume/empty pool)."""


class Date(ctypes.Structure):
    _fields_ = [("year", ctypes.c_int32), ("month", c_uint8), ("day", c_uint8)]


class Time(ctypes.Structure):
    _fields_ = [
        ("hour", c_uint8),
        ("minute", c_uint8),
        ("second", c_uint8),
        ("nanosecond", c_uint32),
    ]


class DateTime(ctypes.Structure):
    _fields_ = [("date", Date), ("time", Time)]


class BytesResult(ctypes.Structure):
    _fields_ = [("data", POINTER(c_uint8)), ("len", c_size_t)]


class StringResult(ctypes.Structure):
    _fields_ = [("data", POINTER(ctypes.c_char)), ("len", c_size_t)]


OutputCallback = ctypes.CFUNCTYPE(None, c_void_p, POINTER(ctypes.c_char), c_size_t)

_Void = c_void_p
# Every bound function: (name, restype, [argtypes]).
_PROTOTYPES: list[tuple[str, object, list[object]]] = [
    ("hegel_context_new", _Void, []),
    ("hegel_context_free", ctypes.c_int, [_Void]),
    ("hegel_context_last_error", c_char_p, [_Void]),
    ("hegel_version", ctypes.c_int, [_Void, POINTER(c_char_p)]),
    ("hegel_settings_new", ctypes.c_int, [_Void, POINTER(_Void)]),
    ("hegel_settings_new_for_profile", ctypes.c_int, [_Void, c_char_p, POINTER(_Void)]),
    ("hegel_settings_free", ctypes.c_int, [_Void, _Void]),
    ("hegel_settings_set_test_cases", ctypes.c_int, [_Void, _Void, c_uint64]),
    ("hegel_settings_set_verbosity", ctypes.c_int, [_Void, _Void, c_uint32]),
    ("hegel_settings_set_seed", ctypes.c_int, [_Void, _Void, c_uint64, c_bool]),
    ("hegel_settings_set_derandomize", ctypes.c_int, [_Void, _Void, c_bool]),
    ("hegel_settings_set_report_multiple_failures", ctypes.c_int, [_Void, _Void, c_bool]),
    ("hegel_settings_set_show_statistics", ctypes.c_int, [_Void, _Void, c_bool]),
    ("hegel_settings_set_unbounded_choices", ctypes.c_int, [_Void, _Void, c_bool]),
    ("hegel_settings_set_database", ctypes.c_int, [_Void, _Void, c_char_p]),
    ("hegel_settings_set_database_key", ctypes.c_int, [_Void, _Void, c_char_p]),
    ("hegel_settings_set_phases", ctypes.c_int, [_Void, _Void, c_uint32]),
    ("hegel_settings_set_suppress_health_check", ctypes.c_int, [_Void, _Void, c_uint32]),
    ("hegel_settings_set_print_blob", ctypes.c_int, [_Void, _Void, c_bool]),
    ("hegel_settings_set_backend", ctypes.c_int, [_Void, _Void, c_uint32]),
    ("hegel_run_start", ctypes.c_int, [_Void, _Void, OutputCallback, c_void_p, POINTER(_Void)]),
    ("hegel_next_test_case", ctypes.c_int, [_Void, _Void, POINTER(_Void)]),
    ("hegel_run_result", ctypes.c_int, [_Void, _Void, POINTER(_Void)]),
    ("hegel_run_result_free", ctypes.c_int, [_Void, _Void]),
    ("hegel_run_free", ctypes.c_int, [_Void, _Void]),
    ("hegel_run_result_status", ctypes.c_int, [_Void, _Void, POINTER(ctypes.c_int)]),
    ("hegel_run_result_error", ctypes.c_int, [_Void, _Void, POINTER(c_char_p)]),
    ("hegel_run_result_failure_count", ctypes.c_int, [_Void, _Void, POINTER(c_size_t)]),
    ("hegel_run_result_failure", ctypes.c_int, [_Void, _Void, c_size_t, POINTER(_Void)]),
    ("hegel_failure_free", ctypes.c_int, [_Void, _Void]),
    ("hegel_failure_origin", ctypes.c_int, [_Void, _Void, POINTER(c_char_p)]),
    ("hegel_failure_reproduction_blob", ctypes.c_int, [_Void, _Void, POINTER(c_char_p)]),
    (
        "hegel_test_case_from_blob",
        ctypes.c_int,
        [_Void, _Void, c_char_p, OutputCallback, c_void_p, POINTER(_Void)],
    ),
    ("hegel_test_case_free", ctypes.c_int, [_Void, _Void]),
    ("hegel_test_case_is_nondeterministic", ctypes.c_int, [_Void, _Void, POINTER(c_bool)]),
    ("hegel_test_case_clone", ctypes.c_int, [_Void, _Void, POINTER(_Void)]),
    ("hegel_test_case_set_worker", ctypes.c_int, [_Void, _Void, c_int64]),
    ("hegel_mark_complete", ctypes.c_int, [_Void, _Void, c_uint32, c_char_p]),
    (
        "hegel_generate_boolean",
        ctypes.c_int,
        [_Void, _Void, c_double, c_bool, c_bool, POINTER(c_bool)],
    ),
    ("hegel_generate_integer", ctypes.c_int, [_Void, _Void, c_int64, c_int64, POINTER(c_int64)]),
    (
        "hegel_generate_float",
        ctypes.c_int,
        [
            _Void,
            _Void,
            c_uint32,
            c_double,
            c_double,
            c_bool,
            c_bool,
            c_bool,
            c_bool,
            c_double,
            POINTER(c_double),
        ],
    ),
    (
        "hegel_generate_bytes",
        ctypes.c_int,
        [_Void, _Void, c_uint64, c_uint64, POINTER(BytesResult)],
    ),
    ("hegel_generate_bytes_result_free", ctypes.c_int, [_Void, POINTER(BytesResult)]),
    (
        "hegel_string_generator_text",
        ctypes.c_int,
        [
            _Void,
            c_uint64,
            c_uint64,
            c_char_p,
            c_uint32,
            c_uint32,
            POINTER(c_char_p),
            c_size_t,
            POINTER(c_char_p),
            c_size_t,
            POINTER(c_uint8),
            c_size_t,
            POINTER(c_uint8),
            c_size_t,
            POINTER(_Void),
        ],
    ),
    (
        "hegel_string_generator_regex",
        ctypes.c_int,
        [_Void, c_char_p, c_bool, _Void, POINTER(_Void)],
    ),
    ("hegel_string_generator_email", ctypes.c_int, [_Void, POINTER(_Void)]),
    ("hegel_string_generator_url", ctypes.c_int, [_Void, POINTER(_Void)]),
    ("hegel_string_generator_domain", ctypes.c_int, [_Void, c_uint64, POINTER(_Void)]),
    ("hegel_string_generator_free", ctypes.c_int, [_Void, _Void]),
    ("hegel_generate_string", ctypes.c_int, [_Void, _Void, _Void, POINTER(StringResult)]),
    ("hegel_generate_string_result_free", ctypes.c_int, [_Void, POINTER(StringResult)]),
    ("hegel_generate_date", ctypes.c_int, [_Void, _Void, Date, Date, POINTER(Date)]),
    ("hegel_generate_time", ctypes.c_int, [_Void, _Void, Time, Time, POINTER(Time)]),
    (
        "hegel_generate_datetime",
        ctypes.c_int,
        [_Void, _Void, DateTime, DateTime, POINTER(DateTime)],
    ),
    ("hegel_generate_uuid", ctypes.c_int, [_Void, _Void, c_uint8, c_bool, POINTER(c_uint8)]),
    ("hegel_generate_ipv4", ctypes.c_int, [_Void, _Void, POINTER(c_uint8)]),
    ("hegel_generate_ipv6", ctypes.c_int, [_Void, _Void, POINTER(c_uint8)]),
    ("hegel_new_collection", ctypes.c_int, [_Void, _Void, c_uint64, c_uint64, POINTER(_Void)]),
    ("hegel_collection_more", ctypes.c_int, [_Void, _Void, _Void, POINTER(c_bool)]),
    ("hegel_collection_reject", ctypes.c_int, [_Void, _Void, _Void, c_char_p]),
    ("hegel_collection_free", ctypes.c_int, [_Void, _Void]),
    ("hegel_new_pool", ctypes.c_int, [_Void, _Void, POINTER(_Void)]),
    ("hegel_pool_add", ctypes.c_int, [_Void, _Void, _Void, POINTER(c_int64)]),
    ("hegel_pool_generate", ctypes.c_int, [_Void, _Void, _Void, c_bool, POINTER(c_int64)]),
    ("hegel_pool_free", ctypes.c_int, [_Void, _Void]),
    (
        "hegel_new_state_machine",
        ctypes.c_int,
        [
            _Void,
            _Void,
            POINTER(c_char_p),
            POINTER(c_int64),
            POINTER(c_double),
            c_size_t,
            POINTER(c_char_p),
            POINTER(c_bool),
            c_size_t,
            c_int64,
            c_int64,
            c_int64,
            POINTER(_Void),
            POINTER(c_int64),
        ],
    ),
    ("hegel_state_machine_next_group", ctypes.c_int, [_Void, _Void, _Void, POINTER(c_int64)]),
    (
        "hegel_state_machine_next_rule",
        ctypes.c_int,
        [_Void, _Void, _Void, c_int64, POINTER(c_int64)],
    ),
    ("hegel_state_machine_rule_rejected", ctypes.c_int, [_Void, _Void, _Void, c_int64]),
    (
        "hegel_state_machine_should_check_invariant",
        ctypes.c_int,
        [_Void, _Void, _Void, c_int64, POINTER(c_bool)],
    ),
    ("hegel_state_machine_free", ctypes.c_int, [_Void, _Void]),
    ("hegel_start_span", ctypes.c_int, [_Void, _Void, c_uint64]),
    ("hegel_stop_span", ctypes.c_int, [_Void, _Void, c_bool]),
    ("hegel_label_from_name", ctypes.c_int, [_Void, c_char_p, POINTER(c_uint64)]),
    ("hegel_note", ctypes.c_int, [_Void, _Void, POINTER(c_uint8), c_size_t]),
    ("hegel_event", ctypes.c_int, [_Void, _Void, c_char_p]),
    ("hegel_event_value", ctypes.c_int, [_Void, _Void, c_double, c_char_p]),
    ("hegel_target", ctypes.c_int, [_Void, _Void, c_double, c_char_p]),
]

_EXPECTED_VERSION = "@HEGEL_EXPECTED_VERSION@"


def _candidate_paths() -> list[str]:
    candidates: list[str] = []
    override = os.environ.get("HEGEL_LIBRARY_PATH")
    if override:
        candidates.append(override)
    if not _DEFAULT_LIBRARY.startswith("@"):
        candidates.append(_DEFAULT_LIBRARY)
    return candidates


def _load_library() -> ctypes.CDLL:
    errors: list[str] = []
    for candidate in _candidate_paths():
        try:
            return ctypes.CDLL(candidate)
        except OSError as error:
            errors.append(str(error))
    raise HegelError(
        0,
        "libhegel_c not found; set HEGEL_LIBRARY_PATH or use the Nix-packaged binding. "
        + "; ".join(errors),
    )


class Lib:
    """Loaded libhegel_c handle with prototypes registered, once per process."""

    _instance: Lib | None = None

    def __init__(self) -> None:
        self._cdll = _load_library()
        for name, restype, argtypes in _PROTOTYPES:
            function = getattr(self._cdll, name)
            function.restype = restype
            function.argtypes = argtypes  # type: ignore[assignment]
        self.ctx: int = self._cdll.hegel_context_new()
        self._checked_version()

    def _checked_version(self) -> None:
        out = c_char_p()
        if self._cdll.hegel_version(self.ctx, ctypes.byref(out)) != Result.OK:
            raise HegelError(0, "hegel_version call failed")
        version = out.value.decode() if out.value else "<none>"
        expected = os.environ.get("HEGEL_EXPECTED_VERSION") or (
            _EXPECTED_VERSION if not _EXPECTED_VERSION.startswith("@") else None
        )
        if expected and version != expected:
            raise HegelError(
                0,
                f"libhegel version mismatch: binding expects {expected}, library reports {version}",
            )

    def __getattr__(self, name: str) -> Callable[..., int]:
        function = getattr(self._cdll, name, None)
        if function is None:
            raise AttributeError(name)

        def call(*args: object) -> int:
            with _ENGINE_LOCK:
                return int(function(*args))

        return call

    def last_error(self) -> str:
        with _ENGINE_LOCK:
            message = self._cdll.hegel_context_last_error(self.ctx)
        return message.decode() if message else ""


def lib() -> Lib:
    if Lib._instance is None:
        Lib._instance = Lib()
    return Lib._instance


def check(rc: int) -> None:
    """Map a libhegel result code: OK passes, draw-level codes become control
    exceptions, everything else becomes HegelError with the engine message."""
    if rc == Result.OK:
        return
    if rc == Result.STOP_TEST:
        raise StopTest
    if rc == Result.ASSUME:
        raise AssumptionRejected
    engine = lib()
    raise HegelError(rc, engine.last_error())


CHECK_EXCEPTIONS = (StopTest, AssumptionRejected)


def _free_context() -> None:
    if Lib._instance is not None:
        Lib._instance.hegel_context_free(Lib._instance.ctx)


atexit.register(_free_context)
