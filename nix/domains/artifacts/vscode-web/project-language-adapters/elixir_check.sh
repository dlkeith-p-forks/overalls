#!/bin/sh

# @cc [owner:ghuntley,label:build] project-elixir-check
# This adapter MUST execute project PATH elixir with unchanged string arguments,
# including the upstream empty-stdout check; no version flag may be added.
if ! command -v elixir >/dev/null 2>&1; then
  printf '%s\n' 'project_elixir_unavailable' >&2
  exit 127
fi
exec elixir "$@"
