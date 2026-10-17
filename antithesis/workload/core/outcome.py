"""Observations preserve uncertainty from unavailable transports and oracle reads."""

from dataclasses import dataclass
from enum import Enum


class State(Enum):
    OBSERVED = "observed"
    REFUSED = "refused"
    UNAVAILABLE = "unavailable"


@dataclass(frozen=True)
class Observation[T]:
    state: State
    value: T | None = None
    status: int | None = None

    def __post_init__(self) -> None:
        if self.state is State.UNAVAILABLE and (self.value is not None or self.status is not None):
            raise ValueError("unavailable observation cannot carry a verdict")
        if self.state is State.REFUSED and (
            self.value is not None or self.status is None or not 400 <= self.status < 500
        ):
            raise ValueError("refusal requires an HTTP error status and no value")

    @classmethod
    def unavailable(cls) -> "Observation[T]":
        """@cc [owner:ghuntley,label:verification] observation-unavailability-is-unknown
        A transport or oracle failure MUST remain UNAVAILABLE, with no value; it
        MUST NOT be interpreted as a SUT refusal, absent effect or passing property.
        """
        return cls(State.UNAVAILABLE)

    @classmethod
    def observed(cls, value: T, status: int | None = None) -> "Observation[T]":
        return cls(State.OBSERVED, value, status)

    @classmethod
    def refused(cls, status: int) -> "Observation[T]":
        return cls(State.REFUSED, status=status)
