"""Apply the one reviewed observation-context seam to the disposable fixture release."""

import sys
from pathlib import Path

SOURCE = """  def observe_for_readiness(
        identity,
        snapshots,
        placement_id,
        staged \\\\ MapSet.new(),
        usage \\\\ :exact
      )
      when usage in [:exact, :identity] do
    diagnostic = if OverallsProtocol.uuid?(placement_id), do: placement_id, else: nil
    observe_with_diagnostics(identity, snapshots, diagnostic, usage, staged)
  end"""
REPLACEMENT = """  def observe_for_readiness(
        identity,
        snapshots,
        placement_id,
        staged \\\\ MapSet.new(),
        usage \\\\ :exact
      )
      when usage in [:exact, :identity] do
    diagnostic = if OverallsProtocol.uuid?(placement_id), do: placement_id, else: nil
    Lilly.CloneObservationFixture.around(diagnostic, snapshots, fn ->
      observe_with_diagnostics(identity, snapshots, diagnostic, usage, staged)
    end)
  end"""


def main() -> None:
    """@cc [owner:ghuntley,label:verification] clone-observation-exact-source-seam
    The fixture build MUST refuse changed or duplicate observer definitions.
    Only the exact reviewed readiness entry may wrap its unchanged observer call.
    """
    source = Path(sys.argv[1])
    text = source.read_text()
    if text.count(SOURCE) != 1:
        raise SystemExit("Clone observation fixture seam changed")
    source.write_text(text.replace(SOURCE, REPLACEMENT, 1))


if __name__ == "__main__":
    main()
