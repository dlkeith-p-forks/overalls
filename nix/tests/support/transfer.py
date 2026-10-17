"""Private machine-to-machine delivery for the assembled framework drivers."""

from typing import Protocol


class CopyingMachine(Protocol):
    """Transport methods supplied by the composed NixOS test driver machine."""

    def copy_from_machine(self, source: str, target_dir: str = "") -> None: ...

    def copy_from_host(self, source: str, target: str) -> None: ...


def transfer(
    source_machine: CopyingMachine, source: str, target_machine: CopyingMachine, target: str
) -> None:
    """@cc [owner:ghuntley,label:security] private-fixture-transfer
    Fixture transfers MUST use an absolute private temporary directory outside
    retained test output, remove the local copy on exit, and never print it.
    """
    from pathlib import Path
    from tempfile import TemporaryDirectory

    with TemporaryDirectory(prefix="overalls-transfer-private-") as directory:
        source_machine.copy_from_machine(source, directory)
        target_machine.copy_from_host(str(Path(directory) / Path(source).name), target)
