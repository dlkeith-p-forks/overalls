# Refuses committed merge-conflict markers in tracked text files.
#
# Usage: elixir scripts/check_conflict_markers.exs [PATH...]
# Without paths, every file tracked by git is checked. Exits non-zero and lists
# `path:line` for each marker found. Bare "=======" lines are not markers on
# their own (Markdown uses them as heading underlines), so only the opening,
# base and closing markers followed by a space or end of line are reported.
Code.require_file("conflict_markers.ex", __DIR__)

paths =
  case System.argv() do
    [] -> Overalls.ConflictMarkers.tracked()
    paths -> paths
  end

case Overalls.ConflictMarkers.violations(paths) do
  [] ->
    IO.puts("No merge-conflict markers in #{length(paths)} files")

  found ->
    for {path, line} <- found, do: IO.puts(:stderr, "#{path}:#{line}: merge-conflict marker")
    System.halt(1)
end
