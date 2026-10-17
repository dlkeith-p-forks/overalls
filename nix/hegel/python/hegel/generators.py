"""Generator objects drawn from libhegel.

A `Generator[T]` describes a drawable value. Test bodies receive values via
`tc.draw(generators.integers(...))` or through `@given(name=generator)`.
All composites draw through the engine's choice stream so shrinking works.
"""

from __future__ import annotations

import atexit
import ctypes
import datetime
import math
import socket
import uuid as uuid_module
from collections.abc import Callable, Sequence
from ctypes import byref, c_bool, c_double, c_int64, c_uint8, c_uint64
from typing import TYPE_CHECKING, Any

from hegel._lib import (
    AssumptionRejected,
    BytesResult,
    Date,
    DateTime,
    StringResult,
    Time,
    check,
    lib,
)

if TYPE_CHECKING:
    from hegel.engine import TestCase

_INT64_MIN = -(2**63)
_INT64_MAX = 2**63 - 1
_UINT32_MAX = 2**32 - 1


class Generator[T]:
    """A drawable value; composed generators preserve shrinking structure."""

    def __init__(self, draw: Callable[[TestCase], T]) -> None:
        self._draw_fn = draw

    def draw(self, tc: TestCase) -> T:
        return self._draw_fn(tc)

    def map[U](self, transform: Callable[[T], U]) -> Generator[U]:
        return Generator(lambda tc: transform(self._draw_fn(tc)))

    def filter(self, predicate: Callable[[T], bool], *, max_retries: int = 50) -> Generator[T]:
        label = _next_filter_label()

        def attempt(tc: TestCase) -> T:
            engine = lib()
            for _ in range(max_retries):
                check(engine.hegel_start_span(engine.ctx, tc._ptr, label))
                try:
                    value = self._draw_fn(tc)
                except BaseException:
                    check(engine.hegel_stop_span(engine.ctx, tc._ptr, True))
                    raise
                if predicate(value):
                    check(engine.hegel_stop_span(engine.ctx, tc._ptr, False))
                    return value
                check(engine.hegel_stop_span(engine.ctx, tc._ptr, True))
            raise AssumptionRejected("filter predicate rejected too many draws")

        return Generator(attempt)


_LABELS: dict[str, int] = {}
_label_counter = 0


def _label_for(name: str) -> int:
    if name not in _LABELS:
        engine = lib()
        out = c_uint64()
        check(engine.hegel_label_from_name(engine.ctx, name.encode(), byref(out)))
        _LABELS[name] = out.value
    return _LABELS[name]


def _next_filter_label() -> int:
    global _label_counter
    _label_counter += 1
    return _label_for(f"hegel-python.filter.{_label_counter}")


def integers(min_value: int = _INT64_MIN, max_value: int = _INT64_MAX) -> Generator[int]:
    def draw(tc: TestCase) -> int:
        engine = lib()
        out = c_int64()
        check(engine.hegel_generate_integer(engine.ctx, tc._ptr, min_value, max_value, byref(out)))
        return int(out.value)

    return Generator(draw)


def booleans(p: float = 0.5) -> Generator[bool]:
    def draw(tc: TestCase) -> bool:
        engine = lib()
        out = c_bool()
        check(engine.hegel_generate_boolean(engine.ctx, tc._ptr, p, False, False, byref(out)))
        return bool(out.value)

    return Generator(draw)


def floats(
    min_value: float = -math.inf,
    max_value: float = math.inf,
    *,
    width: int = 64,
    allow_nan: bool = False,
    allow_infinity: bool = False,
    exclude_min: bool = False,
    exclude_max: bool = False,
    smallest_nonzero_magnitude: float = 5e-324,
) -> Generator[float]:
    if width not in (32, 64):
        raise ValueError("floats(width=) must be 32 or 64")

    def draw(tc: TestCase) -> float:
        engine = lib()
        out = c_double()
        check(
            engine.hegel_generate_float(
                engine.ctx,
                tc._ptr,
                width,
                min_value,
                max_value,
                allow_nan,
                allow_infinity,
                exclude_min,
                exclude_max,
                smallest_nonzero_magnitude,
                byref(out),
            )
        )
        return float(out.value)

    return Generator(draw)


def binary(min_size: int = 0, max_size: int = 1024) -> Generator[bytes]:
    def draw(tc: TestCase) -> bytes:
        engine = lib()
        result = BytesResult()
        try:
            check(
                engine.hegel_generate_bytes(engine.ctx, tc._ptr, min_size, max_size, byref(result))
            )
            return ctypes.string_at(ctypes.cast(result.data, ctypes.c_void_p), result.len)
        finally:
            engine.hegel_generate_bytes_result_free(engine.ctx, byref(result))

    return Generator(draw)


_STRING_GENERATORS: dict[tuple[Any, ...], int] = {}


def _cached_string_generator(key: tuple[Any, ...], build: Callable[[], int]) -> int:
    if key not in _STRING_GENERATORS:
        _STRING_GENERATORS[key] = build()
    return _STRING_GENERATORS[key]


def _release_string_generators() -> None:
    if _STRING_GENERATORS:
        engine = lib()
        for handle in _STRING_GENERATORS.values():
            engine.hegel_string_generator_free(engine.ctx, handle)
        _STRING_GENERATORS.clear()


atexit.register(_release_string_generators)


def _text_generator_handle(
    min_size: int,
    max_size: int,
    codec: str | None,
    min_codepoint: int,
    max_codepoint: int,
    categories: Sequence[str] | None,
    exclude_categories: Sequence[str] | None,
    include_characters: str | None,
    exclude_characters: str | None,
) -> int:
    engine = lib()
    key = (
        "text",
        min_size,
        max_size,
        codec,
        min_codepoint,
        max_codepoint,
        tuple(categories) if categories is not None else None,
        tuple(exclude_categories) if exclude_categories is not None else None,
        include_characters,
        exclude_characters,
    )

    def build() -> int:
        cats = (
            (ctypes.c_char_p * len(categories))(*[c.encode() for c in categories])
            if categories is not None
            else None
        )
        xcats = (
            (ctypes.c_char_p * len(exclude_categories))(*[c.encode() for c in exclude_categories])
            if exclude_categories is not None
            else None
        )
        inc = include_characters.encode() if include_characters else None
        exc = exclude_characters.encode() if exclude_characters else None
        inc_buf = (c_uint8 * len(inc)).from_buffer_copy(inc) if inc is not None else None
        exc_buf = (c_uint8 * len(exc)).from_buffer_copy(exc) if exc is not None else None
        out = ctypes.c_void_p()
        check(
            engine.hegel_string_generator_text(
                engine.ctx,
                min_size,
                max_size,
                codec.encode() if codec else None,
                min_codepoint,
                max_codepoint,
                cats,
                len(categories) if categories is not None else 0,
                xcats,
                len(exclude_categories) if exclude_categories is not None else 0,
                inc_buf,
                len(inc) if inc is not None else 0,
                exc_buf,
                len(exc) if exc is not None else 0,
                byref(out),
            )
        )
        assert out.value is not None
        return int(out.value)

    return _cached_string_generator(key, build)


def text(
    alphabet: str | None = None,
    *,
    min_size: int = 0,
    max_size: int = 255,
    codec: str | None = None,
    min_codepoint: int = 0,
    max_codepoint: int = _UINT32_MAX,
    categories: Sequence[str] | None = None,
    exclude_categories: Sequence[str] | None = None,
    exclude_characters: str | None = None,
) -> Generator[str]:
    if min_size > max_size:
        raise ValueError("text() requires min_size <= max_size")
    if alphabet is not None and categories is not None:
        raise ValueError("text() accepts either alphabet or categories, not both")
    if alphabet is not None:
        # libhegel's include_characters is additive onto the codec/category base
        # set; an exclusive alphabet needs an empty category base (non-NULL).
        categories = []
    handle = _text_generator_handle(
        min_size,
        max_size,
        codec,
        min_codepoint,
        max_codepoint,
        categories,
        exclude_categories,
        alphabet,
        exclude_characters,
    )
    return _StringBackedGenerator(lambda tc: _draw_string(tc, handle), handle)


def _draw_string(tc: TestCase, handle: int) -> str:
    engine = lib()
    result = StringResult()
    try:
        check(engine.hegel_generate_string(engine.ctx, tc._ptr, handle, byref(result)))
        raw = ctypes.string_at(ctypes.cast(result.data, ctypes.c_void_p), result.len)
        return raw.decode("utf-8")
    finally:
        engine.hegel_generate_string_result_free(engine.ctx, byref(result))


def from_regex(
    pattern: str, *, fullmatch: bool = True, alphabet: Generator[str] | None = None
) -> Generator[str]:
    if alphabet is not None and not isinstance(alphabet, _StringBackedGenerator):
        raise TypeError(
            "from_regex(alphabet=) requires a string-backed generator (text(), emails(), ...)"
        )
    alphabet_handle = alphabet._string_handle() if alphabet is not None else None

    def build() -> int:
        engine = lib()
        out = ctypes.c_void_p()
        check(
            engine.hegel_string_generator_regex(
                engine.ctx, pattern.encode(), fullmatch, alphabet_handle, byref(out)
            )
        )
        assert out.value is not None
        return int(out.value)

    handle = _cached_string_generator(("regex", pattern, fullmatch, alphabet_handle), build)
    return Generator(lambda tc: _draw_string(tc, handle))


class _StringBackedGenerator(Generator[str]):
    def __init__(self, draw: Callable[[TestCase], str], handle: int) -> None:
        super().__init__(draw)
        self._handle = handle

    def _string_handle(self) -> int:
        return self._handle


def emails() -> Generator[str]:
    def build() -> int:
        engine = lib()
        out = ctypes.c_void_p()
        check(engine.hegel_string_generator_email(engine.ctx, byref(out)))
        assert out.value is not None
        return int(out.value)

    handle = _cached_string_generator(("email",), build)
    return _StringBackedGenerator(lambda tc: _draw_string(tc, handle), handle)


def urls() -> Generator[str]:
    def build() -> int:
        engine = lib()
        out = ctypes.c_void_p()
        check(engine.hegel_string_generator_url(engine.ctx, byref(out)))
        assert out.value is not None
        return int(out.value)

    handle = _cached_string_generator(("url",), build)
    return _StringBackedGenerator(lambda tc: _draw_string(tc, handle), handle)


def domains(max_length: int = 255) -> Generator[str]:
    def build() -> int:
        engine = lib()
        out = ctypes.c_void_p()
        check(engine.hegel_string_generator_domain(engine.ctx, max_length, byref(out)))
        assert out.value is not None
        return int(out.value)

    handle = _cached_string_generator(("domain", max_length), build)
    return _StringBackedGenerator(lambda tc: _draw_string(tc, handle), handle)


def lists[T](
    elements: Generator[T], *, min_size: int = 0, max_size: int = 16
) -> Generator[list[T]]:
    label = _label_for("hegel-python.lists")

    def draw(tc: TestCase) -> list[T]:
        engine = lib()
        check(engine.hegel_start_span(engine.ctx, tc._ptr, label))
        collection = ctypes.c_void_p()
        check(
            engine.hegel_new_collection(engine.ctx, tc._ptr, min_size, max_size, byref(collection))
        )
        assert collection.value is not None
        out: list[T] = []
        try:
            while True:
                more = c_bool()
                check(engine.hegel_collection_more(engine.ctx, tc._ptr, collection, byref(more)))
                if not more.value:
                    break
                out.append(elements._draw_fn(tc))
        finally:
            engine.hegel_collection_free(engine.ctx, collection)
            check(engine.hegel_stop_span(engine.ctx, tc._ptr, False))
        return out

    return Generator(draw)


def sampled_from[T](values: Sequence[T]) -> Generator[T]:
    if not values:
        raise ValueError("sampled_from requires at least one value")
    return integers(0, len(values) - 1).map(lambda index: values[index])


def one_of[T](*generators: Generator[T]) -> Generator[T]:
    if not generators:
        raise ValueError("one_of requires at least one generator")
    index = integers(0, len(generators) - 1)
    label = _label_for("hegel-python.one_of")

    def draw(tc: TestCase) -> T:
        engine = lib()
        check(engine.hegel_start_span(engine.ctx, tc._ptr, label))
        try:
            return generators[index._draw_fn(tc)]._draw_fn(tc)
        finally:
            check(engine.hegel_stop_span(engine.ctx, tc._ptr, False))

    return Generator(draw)


def optional[T](inner: Generator[T]) -> Generator[T | None]:
    label = _label_for("hegel-python.optional")

    def draw(tc: TestCase) -> T | None:
        engine = lib()
        check(engine.hegel_start_span(engine.ctx, tc._ptr, label))
        try:
            some = c_bool()
            check(
                engine.hegel_generate_boolean(engine.ctx, tc._ptr, 0.5, False, False, byref(some))
            )
            return inner._draw_fn(tc) if some.value else None
        finally:
            check(engine.hegel_stop_span(engine.ctx, tc._ptr, False))

    return Generator(draw)


def just[T](value: T) -> Generator[T]:
    return Generator(lambda _tc: value)


def fixed_dictionaries(mapping: dict[str, Generator[Any]]) -> Generator[dict[str, Any]]:
    label = _label_for("hegel-python.fixed_dictionaries")

    def draw(tc: TestCase) -> dict[str, Any]:
        engine = lib()
        check(engine.hegel_start_span(engine.ctx, tc._ptr, label))
        try:
            return {key: gen._draw_fn(tc) for key, gen in mapping.items()}
        finally:
            check(engine.hegel_stop_span(engine.ctx, tc._ptr, False))

    return Generator(draw)


def tuples(*generators: Generator[Any]) -> Generator[tuple[Any, ...]]:
    label = _label_for("hegel-python.tuples")

    def draw(tc: TestCase) -> tuple[Any, ...]:
        engine = lib()
        check(engine.hegel_start_span(engine.ctx, tc._ptr, label))
        try:
            return tuple(gen._draw_fn(tc) for gen in generators)
        finally:
            check(engine.hegel_stop_span(engine.ctx, tc._ptr, False))

    return Generator(draw)


def _date_to_c(value: datetime.date) -> Date:
    return Date(value.year, value.month, value.day)


def dates(
    min_value: datetime.date = datetime.date(1, 1, 1),
    max_value: datetime.date = datetime.date(9999, 12, 31),
) -> Generator[datetime.date]:
    def draw(tc: TestCase) -> datetime.date:
        engine = lib()
        out = Date()
        check(
            engine.hegel_generate_date(
                engine.ctx, tc._ptr, _date_to_c(min_value), _date_to_c(max_value), byref(out)
            )
        )
        return datetime.date(out.year, out.month, out.day)

    return Generator(draw)


def _time_to_c(value: datetime.time) -> Time:
    return Time(value.hour, value.minute, value.second, value.microsecond * 1000)


def times(
    min_value: datetime.time = datetime.time(0, 0, 0),
    max_value: datetime.time = datetime.time(23, 59, 59, 999999),
) -> Generator[datetime.time]:
    def draw(tc: TestCase) -> datetime.time:
        engine = lib()
        out = Time()
        check(
            engine.hegel_generate_time(
                engine.ctx, tc._ptr, _time_to_c(min_value), _time_to_c(max_value), byref(out)
            )
        )
        return datetime.time(out.hour, out.minute, out.second, out.nanosecond // 1000)

    return Generator(draw)


def _datetime_to_c(value: datetime.datetime) -> DateTime:
    return DateTime(
        Date(value.year, value.month, value.day),
        Time(value.hour, value.minute, value.second, value.microsecond * 1000),
    )


def datetimes(
    min_value: datetime.datetime = datetime.datetime(1, 1, 1),
    max_value: datetime.datetime = datetime.datetime(9999, 12, 31, 23, 59, 59, 999999),
) -> Generator[datetime.datetime]:
    def draw(tc: TestCase) -> datetime.datetime:
        engine = lib()
        out = DateTime()
        check(
            engine.hegel_generate_datetime(
                engine.ctx,
                tc._ptr,
                _datetime_to_c(min_value),
                _datetime_to_c(max_value),
                byref(out),
            )
        )
        return datetime.datetime(
            out.date.year,
            out.date.month,
            out.date.day,
            out.time.hour,
            out.time.minute,
            out.time.second,
            out.time.nanosecond // 1000,
        )

    return Generator(draw)


def uuids(version: int | None = None) -> Generator[str]:
    if version is not None and not (0 <= version <= 15):
        raise ValueError("uuids(version=) must be in 0..=15")

    def draw(tc: TestCase) -> str:
        engine = lib()
        buffer = (c_uint8 * 16)()
        check(
            engine.hegel_generate_uuid(
                engine.ctx, tc._ptr, version or 0, version is not None, buffer
            )
        )
        return str(uuid_module.UUID(bytes=bytes(buffer)))

    return Generator(draw)


def ip_addresses(v: int = 4) -> Generator[str]:
    if v not in (4, 6):
        raise ValueError("ip_addresses(v=) must be 4 or 6")

    def draw(tc: TestCase) -> str:
        engine = lib()
        size = 4 if v == 4 else 16
        buffer = (c_uint8 * size)()
        if v == 4:
            check(engine.hegel_generate_ipv4(engine.ctx, tc._ptr, buffer))
            return socket.inet_ntoa(bytes(buffer))
        check(engine.hegel_generate_ipv6(engine.ctx, tc._ptr, buffer))
        return socket.inet_ntop(socket.AF_INET6, bytes(buffer))

    return Generator(draw)


def ip_networks(_v: int = 4) -> Generator[str]:
    raise NotImplementedError("ip_networks is not provided by libhegel; compose ip_addresses()")


__all__ = [
    "Generator",
    "binary",
    "booleans",
    "dates",
    "datetimes",
    "domains",
    "emails",
    "fixed_dictionaries",
    "floats",
    "from_regex",
    "integers",
    "ip_addresses",
    "just",
    "lists",
    "one_of",
    "optional",
    "sampled_from",
    "text",
    "times",
    "tuples",
    "urls",
    "uuids",
]
