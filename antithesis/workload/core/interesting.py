"""Per-draw SDK choices over explicit boundary and configured-limit families."""

from collections.abc import Sequence

from antithesis.random import random_choice


def choice[T](values: Sequence[T]) -> T:
    """@cc [owner:ghuntley,label:verification] interesting-values-fresh-sdk-draw
    Every selection MUST call the SDK for that draw. Menus MUST be explicit and
    nonempty; a selected SDK value MUST never become a seed for a separate PRNG.
    """
    if not values:
        raise ValueError("empty interesting-value menu")
    selected = random_choice(list(values))
    if selected not in values:
        raise ValueError("SDK returned a value outside the menu")
    return selected


def nonnegative_limit_family(limit: int, *, maximum: int) -> tuple[int, ...]:
    if not 0 < limit <= maximum:
        raise ValueError("configured limit outside input domain")
    return tuple(sorted({0, 1, max(0, limit - 1), limit, min(maximum, limit + 1), maximum}))
